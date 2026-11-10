-- MIGRAÇÃO V15 — feedback do professor, limpeza segura e manutenção da lixeira.
-- Projeto: abmhfmlttjmwksqhnzwr
-- Execute uma única vez no Supabase > SQL Editor > New query.
-- Preserva banco_questoes, Storage, conteúdo-base das avaliações e usuário do professor.

begin;

-- Colunas da lixeira; IF NOT EXISTS torna a migração segura caso o script anterior já tenha rodado.
alter table public.provas_alunos
    add column if not exists excluida_em timestamptz,
    add column if not exists expira_em timestamptz;
create index if not exists provas_alunos_lixeira_expira_idx
    on public.provas_alunos (expira_em) where excluida_em is not null;

alter table public.respostas_avaliacoes
    add column if not exists feedback_professor text not null default '',
    add column if not exists feedback_questoes jsonb not null default '{}'::jsonb,
    add column if not exists feedback_publicado boolean not null default false,
    add column if not exists feedback_enviado_em timestamptz;

-- O aluno só recebe a devolutiva depois que o professor clicar em publicar.
create or replace function public.buscar_feedback_aluno(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v public.respostas_avaliacoes%rowtype;
begin
    if p_token is null or length(p_token) < 32 then
        return jsonb_build_object('erro', 'Link de feedback inválido.');
    end if;

    select * into v
      from public.respostas_avaliacoes
     where student_token = p_token;

    if not found then
        return jsonb_build_object('erro', 'Feedback não encontrado.');
    end if;

    if not coalesce(v.feedback_publicado, false) then
        return jsonb_build_object('publicado', false, 'mensagem', 'O professor ainda não publicou o feedback.');
    end if;

    return jsonb_build_object(
        'publicado', true,
        'aluno_nome', v.aluno_nome,
        'ano_letivo', v.ano_letivo,
        'serie', v.serie,
        'bimestre', v.bimestre,
        'disciplina', v.disciplina,
        'acertos', v.acertos,
        'nota', v.nota,
        'detalhes', coalesce(v.detalhes, '[]'::jsonb),
        'feedback_professor', coalesce(v.feedback_professor, ''),
        'feedback_questoes', coalesce(v.feedback_questoes, '{}'::jsonb),
        'feedback_enviado_em', v.feedback_enviado_em
    );
end;
$$;
revoke all on function public.buscar_feedback_aluno(text) from public;
grant execute on function public.buscar_feedback_aluno(text) to anon, authenticated;

-- Substitui a função de limpeza. Todos os DELETE têm WHERE pela chave primária.
-- Se a mensagem anterior persistir, confira no Supabase se esta migração foi executada
-- no mesmo projeto que o sistema utiliza.
create or replace function public.zerar_dados_teste_avaliacao()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_resultados integer := 0;
    v_provas integer := 0;
begin
    if auth.uid() is null or not public.usuario_e_professor() then
        return jsonb_build_object('erro', 'Apenas um professor autorizado pode zerar os dados.');
    end if;

    delete from public.respostas_avaliacoes
     where id is not null;
    get diagnostics v_resultados = row_count;

    delete from public.provas_alunos
     where student_token is not null;
    get diagnostics v_provas = row_count;

    update public.dados_professor
       set cadastro_turmas = '{}'::jsonb,
           updated_at = now()
     where user_id = auth.uid();

    return jsonb_build_object(
        'sucesso', true,
        'resultados_removidos', v_resultados,
        'avaliacoes_individuais_removidas', v_provas,
        'cadastros_de_turma_limpos', true,
        'banco_questoes_preservado', true,
        'storage_preservado', true
    );
end;
$$;
revoke all on function public.zerar_dados_teste_avaliacao() from public, anon;
grant execute on function public.zerar_dados_teste_avaliacao() to authenticated;

-- Expiração automática das avaliações que permaneceram na lixeira por 15 dias.
create or replace function public.expurgar_provas_lixeira()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_removidas integer := 0;
begin
    delete from public.provas_alunos
     where student_token is not null
       and excluida_em is not null
       and expira_em is not null
       and expira_em <= now();
    get diagnostics v_removidas = row_count;
    return v_removidas;
end;
$$;
revoke all on function public.expurgar_provas_lixeira() from public, anon, authenticated;
grant execute on function public.expurgar_provas_lixeira() to service_role;

commit;

-- VERIFICAÇÕES:
-- 1. Confirma as colunas de feedback:
-- select column_name from information_schema.columns
-- where table_schema='public' and table_name='respostas_avaliacoes' and column_name like 'feedback_%';
-- 2. Confirma as funções:
-- select proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and proname in ('buscar_feedback_aluno','zerar_dados_teste_avaliacao','expurgar_provas_lixeira');


-- Agenda a remoção automática uma vez por hora. É idempotente: não cria jobs duplicados.
do $$
declare
    v_existe boolean := false;
begin
    begin
        execute 'create extension if not exists pg_cron';
    exception when others then
        raise notice 'pg_cron não foi habilitado automaticamente. Ative-o em Supabase > Integrations > Cron.';
    end;

    if exists (select 1 from pg_namespace where nspname = 'cron') then
        begin
            execute 'select exists (select 1 from cron.job where jobname = $1)'
                into v_existe using 'limpar-lixeira-avaliacoes-hora';
            if not v_existe then
                execute $job$select cron.schedule('limpar-lixeira-avaliacoes-hora', '0 * * * *', 'select public.expurgar_provas_lixeira();')$job$;
            end if;
        exception when others then
            raise notice 'Não foi possível agendar Cron automaticamente. A limpeza ao abrir o painel continua ativa; confira Supabase > Integrations > Cron.';
        end;
    end if;
end;
$$;
