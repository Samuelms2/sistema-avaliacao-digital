-- MIGRAÇÃO 2026-11-09 — sincronização multi-dispositivo, lixeira de 15 dias e limpeza segura.
-- Execute este arquivo UMA VEZ no SQL Editor do projeto Supabase abmhfmlttjmwksqhnzwr,
-- depois do SQL inicial que criou banco_questoes, provas_alunos, respostas_avaliacoes e usuario_e_professor().

begin;

-- 1) Perfil sincronizado: turmas/alunos e configurações compartilhados entre computador e celular.
create table if not exists public.dados_professor (
    user_id uuid primary key references auth.users(id) on delete cascade,
    cadastro_turmas jsonb not null default '{}'::jsonb,
    configuracoes jsonb not null default '{}'::jsonb,
    updated_at timestamptz not null default now()
);
alter table public.dados_professor enable row level security;
drop policy if exists "professor gerencia seus dados sincronizados" on public.dados_professor;
create policy "professor gerencia seus dados sincronizados" on public.dados_professor
    for all to authenticated
    using (public.usuario_e_professor() and user_id = auth.uid())
    with check (public.usuario_e_professor() and user_id = auth.uid());
grant select, insert, update, delete on public.dados_professor to authenticated;

-- 2) Lixeira reversível das avaliações individuais. O conteúdo das questões não é alterado.
alter table public.provas_alunos add column if not exists excluida_em timestamptz;
alter table public.provas_alunos add column if not exists expira_em timestamptz;
create index if not exists provas_alunos_lixeira_expira_idx
    on public.provas_alunos (expira_em)
    where excluida_em is not null;

-- 3) Atualiza as RPCs para que links enviados à lixeira não continuem respondíveis.
create or replace function public.buscar_prova_aluno(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v public.provas_alunos%rowtype;
    v_questoes jsonb;
begin
    select * into v from public.provas_alunos
    where student_token = p_token;

    if not found then
        return jsonb_build_object('erro', 'Prova não encontrada. Solicite ao professor um novo link.');
    end if;
    if v.excluida_em is not null then
        return jsonb_build_object('erro', 'Esta avaliação foi enviada à lixeira pelo professor e não está disponível.');
    end if;

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'numero', q->'numero',
            'enunciado', q->'enunciado',
            'imgEnunciado', coalesce(q->'imgEnunciado', 'null'::jsonb),
            'alternativas', (
                select coalesce(jsonb_agg(
                    jsonb_build_object(
                        'letter', a->'letter',
                        'text', a->'text',
                        'img', coalesce(a->'img', 'null'::jsonb)
                    ) order by a->>'letter'
                ), '[]'::jsonb)
                from jsonb_array_elements(q->'alternativas') a
            )
        ) order by (q->>'numero')::integer
    ), '[]'::jsonb)
    into v_questoes
    from jsonb_array_elements(v.prova->'questoes') q;

    return jsonb_build_object(
        'concluida', v.concluida,
        'aguardando_nova_chance', v.aguardando_nova_chance,
        'tentativa', v.tentativa,
        'ultima_nota', v.last_note,
        'ultimos_acertos', v.last_hits,
        'total_questoes', coalesce(v.total_questoes, jsonb_array_length(v.prova->'questoes')),
        'respostas_rascunho', coalesce(v.draft_answers, '{}'::jsonb),
        'prova', jsonb_build_object(
            'alunoName', v.prova->'alunoName',
            'alunoSerie', v.prova->'alunoSerie',
            'alunoTurma', v.prova->'alunoTurma',
            'escola', v.prova->'escola',
            'titulo', v.prova->'titulo',
            'disciplina', v.prova->'disciplina',
            'anoLetivo', v.prova->'anoLetivo',
            'professor', v.prova->'professor',
            'serie', v.prova->'alunoSerie',
            'turma', v.prova->'alunoTurma',
            'questoes', v_questoes
        )
    );
end;
$$;

create or replace function public.salvar_rascunho_avaliacao(p_token text, p_respostas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_count integer;
begin
    update public.provas_alunos
       set draft_answers = coalesce(p_respostas, '{}'::jsonb), updated_at = now()
     where student_token = p_token
       and concluida = false
       and aguardando_nova_chance = false
       and excluida_em is null;
    get diagnostics v_count = row_count;
    if v_count = 0 then
        return jsonb_build_object('erro', 'Rascunho não pode ser alterado: prova inexistente ou já finalizada.');
    end if;
    return jsonb_build_object('salvo', true);
end;
$$;

create or replace function public.finalizar_avaliacao_aluno(p_token text, p_respostas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v public.provas_alunos%rowtype;
    q jsonb;
    v_total integer := 0;
    v_hits integer := 0;
    v_selected text;
    v_correct text;
    v_details jsonb := '[]'::jsonb;
    v_history jsonb;
    v_grade numeric(4,1);
    v_answer jsonb;
begin
    select * into v from public.provas_alunos where student_token = p_token for update;
    if not found then return jsonb_build_object('erro', 'Prova não encontrada.'); end if;
    if v.excluida_em is not null then return jsonb_build_object('erro', 'Esta avaliação foi enviada à lixeira e não pode mais ser respondida.'); end if;
    if v.concluida then return jsonb_build_object('erro', 'Esta avaliação já foi concluída.'); end if;
    if v.aguardando_nova_chance then return jsonb_build_object('erro', 'Escolha SIM ou NÃO para a nova chance antes de enviar.'); end if;

    for q in select value from jsonb_array_elements(v.prova->'questoes')
    loop
        v_total := v_total + 1;
        v_selected := p_respostas->>(q->>'numero');
        v_correct := q->>'letraCorreta';
        if v_selected is not null and v_selected = v_correct then
            v_hits := v_hits + 1;
        end if;
        v_details := v_details || jsonb_build_array(jsonb_build_object(
            'numero', q->'numero',
            'enunciado', q->'enunciado',
            'marcada', v_selected,
            'correta', v_correct,
            'acertou', (v_selected is not null and v_selected = v_correct)
        ));
    end loop;

    if v_total = 0 then return jsonb_build_object('erro', 'A prova não possui questões.'); end if;
    v_grade := round((v_hits::numeric / v_total::numeric) * 10, 1);
    v_history := coalesce(v.historico_tentativas, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'tentativa', v.tentativa,
        'nota', v_grade,
        'acertos', v_hits,
        'total', v_total,
        'respostas', coalesce(p_respostas, '{}'::jsonb),
        'detalhes', v_details,
        'concluida_em', now()
    ));

    if v.tentativa = 1 and v_grade < 6 then
        update public.provas_alunos
           set aguardando_nova_chance = true,
               last_note = v_grade,
               last_hits = v_hits,
               total_questoes = v_total,
               last_answers = coalesce(p_respostas, '{}'::jsonb),
               last_details = v_details,
               historico_tentativas = v_history,
               draft_answers = '{}'::jsonb,
               updated_at = now()
         where student_token = p_token;
        return jsonb_build_object('pode_tentar_novamente', true, 'nota', v_grade, 'acertos', v_hits, 'total_questoes', v_total);
    end if;

    update public.provas_alunos
       set concluida = true,
           aguardando_nova_chance = false,
           last_note = v_grade,
           last_hits = v_hits,
           total_questoes = v_total,
           last_answers = coalesce(p_respostas, '{}'::jsonb),
           last_details = v_details,
           historico_tentativas = v_history,
           draft_answers = '{}'::jsonb,
           updated_at = now()
     where student_token = p_token;

    insert into public.respostas_avaliacoes (
        student_token, aluno_nome, ano_letivo, serie, bimestre, disciplina,
        acertos, nota, origem, detalhes, respostas, tentativas, historico_tentativas, created_at
    ) values (
        p_token, v.aluno_nome, v.ano_letivo, v.serie, v.bimestre, v.disciplina,
        v_hits::text || '/' || v_total::text, v_grade, 'Link Digital Online', v_details,
        coalesce(p_respostas, '{}'::jsonb), v.tentativa, v_history, now()
    )
    on conflict (student_token) do update set
        acertos = excluded.acertos,
        nota = excluded.nota,
        origem = excluded.origem,
        detalhes = excluded.detalhes,
        respostas = excluded.respostas,
        tentativas = excluded.tentativas,
        historico_tentativas = excluded.historico_tentativas,
        created_at = excluded.created_at;

    return jsonb_build_object('pode_tentar_novamente', false, 'concluida', true, 'nota', v_grade, 'acertos', v_hits, 'total_questoes', v_total);
end;
$$;

create or replace function public.reiniciar_tentativa_aluno(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_count integer;
begin
    update public.provas_alunos
       set tentativa = 2,
           aguardando_nova_chance = false,
           draft_answers = '{}'::jsonb,
           updated_at = now()
     where student_token = p_token
       and concluida = false
       and tentativa = 1
       and aguardando_nova_chance = true
       and last_note < 6
       and excluida_em is null;
    get diagnostics v_count = row_count;
    if v_count = 0 then return jsonb_build_object('erro', 'A nova chance não está disponível para esta prova.'); end if;
    return jsonb_build_object('reiniciada', true, 'tentativa', 2);
end;
$$;

create or replace function public.encerrar_sem_nova_chance(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v public.provas_alunos%rowtype;
begin
    select * into v from public.provas_alunos where student_token = p_token for update;
    if not found then return jsonb_build_object('erro', 'Prova não encontrada.'); end if;
    if v.excluida_em is not null then return jsonb_build_object('erro', 'Esta avaliação foi enviada à lixeira e não pode mais ser finalizada.'); end if;
    if v.concluida then return jsonb_build_object('concluida', true); end if;
    if not v.aguardando_nova_chance or v.last_note is null then
        return jsonb_build_object('erro', 'Não há resultado pendente para finalizar.');
    end if;

    update public.provas_alunos
       set concluida = true, aguardando_nova_chance = false, updated_at = now()
     where student_token = p_token;

    insert into public.respostas_avaliacoes (
        student_token, aluno_nome, ano_letivo, serie, bimestre, disciplina,
        acertos, nota, origem, detalhes, respostas, tentativas, historico_tentativas, created_at
    ) values (
        p_token, v.aluno_nome, v.ano_letivo, v.serie, v.bimestre, v.disciplina,
        v.last_hits::text || '/' || v.total_questoes::text, v.last_note,
        'Link Digital Online', coalesce(v.last_details, '[]'::jsonb),
        coalesce(v.last_answers, '{}'::jsonb), 1, coalesce(v.historico_tentativas, '[]'::jsonb), now()
    )
    on conflict (student_token) do update set
        acertos = excluded.acertos, nota = excluded.nota, detalhes = excluded.detalhes,
        respostas = excluded.respostas, tentativas = 1, historico_tentativas = excluded.historico_tentativas, created_at = excluded.created_at;

    return jsonb_build_object('concluida', true, 'nota', v.last_note);
end;
$$;

-- 4) Limpeza dos dados de teste. Preserva banco_questoes, Storage, configurações e usuário professor.
create or replace function public.zerar_dados_teste_avaliacao()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_resultados integer;
    v_provas integer;
begin
    if not public.usuario_e_professor() then
        return jsonb_build_object('erro', 'Apenas um professor autorizado pode zerar os dados.');
    end if;

    delete from public.respostas_avaliacoes;
    get diagnostics v_resultados = row_count;

    delete from public.provas_alunos;
    get diagnostics v_provas = row_count;

    insert into public.dados_professor (user_id, cadastro_turmas, configuracoes, updated_at)
    values (auth.uid(), '{}'::jsonb, '{}'::jsonb, now())
    on conflict (user_id) do update
       set cadastro_turmas = '{}'::jsonb,
           updated_at = now();

    return jsonb_build_object(
        'sucesso', true,
        'resultados_removidos', v_resultados,
        'avaliacoes_individuais_removidas', v_provas,
        'banco_questoes_preservado', true,
        'storage_preservado', true
    );
end;
$$;
revoke all on function public.zerar_dados_teste_avaliacao() from public, anon;
grant execute on function public.zerar_dados_teste_avaliacao() to authenticated;

-- 5) Função usada pelo Cron para expurgar avaliações cuja janela de 15 dias terminou.
create or replace function public.expurgar_provas_lixeira()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_removidas integer;
begin
    delete from public.provas_alunos
     where excluida_em is not null
       and expira_em is not null
       and expira_em <= now();
    get diagnostics v_removidas = row_count;
    return v_removidas;
end;
$$;
revoke all on function public.expurgar_provas_lixeira() from public, anon, authenticated;

-- 6) Publica no Realtime todas as tabelas que precisam sincronizar entre dispositivos.
do $$
declare t text;
begin
    foreach t in array array['dados_professor','banco_questoes','provas_alunos','respostas_avaliacoes'] loop
        if not exists (
            select 1 from pg_publication_tables
             where pubname = 'supabase_realtime'
               and schemaname = 'public'
               and tablename = t
        ) then
            execute format('alter publication supabase_realtime add table public.%I', t);
        end if;
    end loop;
end $$;

commit;

-- 7) Agenda a limpeza automática de hora em hora (15 dias contados da data/hora do envio à lixeira).
-- Se pg_cron não estiver habilitado no projeto, a aplicação também faz a limpeza ao abrir o painel do professor.
do $$
begin
    execute 'create extension if not exists pg_cron';
exception when others then
    raise notice 'pg_cron não pôde ser habilitado automaticamente. Ative Cron em Supabase Dashboard > Integrations > Cron.';
end $$;

do $$
declare v_job_exists boolean := false;
begin
    if exists (select 1 from pg_namespace where nspname = 'cron') then
        execute 'select exists (select 1 from cron.job where jobname = $1)'
            into v_job_exists using 'limpar-lixeira-avaliacoes-hora';
        if not v_job_exists then
            execute $cmd$select cron.schedule('limpar-lixeira-avaliacoes-hora', '0 * * * *', 'select public.expurgar_provas_lixeira();')$cmd$;
        end if;
    end if;
exception when others then
    raise notice 'Não foi possível agendar pg_cron. A limpeza ao abrir o painel continuará ativa; confira Integrations > Cron.';
end $$;

-- Verificação rápida depois da execução:
-- select to_regclass('public.dados_professor') as tabela_sincronizacao,
--        (select count(*) from public.provas_alunos where excluida_em is not null) as provas_na_lixeira;
