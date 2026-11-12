-- MIGRACAO V16: disponibiliza o resultado final no mesmo link individual do aluno.
-- Execute UMA VEZ no SQL Editor do projeto Supabase usado pelo sistema.
-- O gabarito detalhado só e retornado quando a avaliacao esta concluida.

begin;

create or replace function public.buscar_prova_aluno(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v public.provas_alunos%rowtype;
    r public.respostas_avaliacoes%rowtype;
    v_questoes jsonb;
    v_resultado jsonb := null;
    v_hits integer;
    v_total integer;
    v_nota numeric(4,1);
    v_detalhes jsonb;
    v_respostas jsonb;
    v_tentativas integer;
begin
    if p_token is null or length(p_token) < 32 then
        return jsonb_build_object('erro', 'Link individual invalido. Solicite um novo link ao professor.');
    end if;

    select * into v
      from public.provas_alunos
     where student_token = p_token;

    if not found then
        return jsonb_build_object('erro', 'Prova nao encontrada. Solicite ao professor um novo link.');
    end if;

    if v.excluida_em is not null then
        return jsonb_build_object('erro', 'Esta avaliacao foi enviada a lixeira pelo professor e nao esta disponivel.');
    end if;

    select * into r
      from public.respostas_avaliacoes
     where student_token = p_token;

    -- A chave correta nao e incluida no objeto prova. So entra em resultado_final
    -- depois que v.concluida = true.
    if v.concluida then
        v_total := coalesce(v.total_questoes, jsonb_array_length(coalesce(v.prova->'questoes', '[]'::jsonb)));
        v_hits := coalesce(v.last_hits, nullif(split_part(coalesce(r.acertos, ''), '/', 1), '')::integer, 0);
        v_nota := coalesce(v.last_note, r.nota);
        if jsonb_array_length(coalesce(v.last_details, '[]'::jsonb)) > 0 then
            v_detalhes := v.last_details;
        else
            v_detalhes := coalesce(r.detalhes, '[]'::jsonb);
        end if;
        if coalesce(v.last_answers, '{}'::jsonb) <> '{}'::jsonb then
            v_respostas := v.last_answers;
        else
            v_respostas := coalesce(r.respostas, '{}'::jsonb);
        end if;
        v_tentativas := coalesce(r.tentativas, v.tentativa, 1);

        v_resultado := jsonb_build_object(
            'nota', v_nota,
            'acertos', v_hits::text || '/' || v_total::text,
            'acertos_numero', v_hits,
            'total_questoes', v_total,
            'erros', greatest(v_total - v_hits, 0),
            'tentativas', v_tentativas,
            'detalhes', coalesce(v_detalhes, '[]'::jsonb),
            'respostas', coalesce(v_respostas, '{}'::jsonb),
            'concluida_em', coalesce(r.created_at, v.updated_at)
        );
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
      from jsonb_array_elements(coalesce(v.prova->'questoes', '[]'::jsonb)) q;

    return jsonb_build_object(
        'concluida', v.concluida,
        'aguardando_nova_chance', v.aguardando_nova_chance,
        'tentativa', v.tentativa,
        'ultima_nota', v.last_note,
        'ultimos_acertos', v.last_hits,
        'total_questoes', coalesce(v.total_questoes, jsonb_array_length(v_questoes)),
        'respostas_rascunho', coalesce(v.draft_answers, '{}'::jsonb),
        'resultado_final', v_resultado,
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
    v_resultado jsonb;
begin
    select * into v
      from public.provas_alunos
     where student_token = p_token
     for update;

    if not found then return jsonb_build_object('erro', 'Prova nao encontrada.'); end if;
    if v.excluida_em is not null then return jsonb_build_object('erro', 'Esta avaliacao foi enviada a lixeira e nao pode mais ser respondida.'); end if;
    if v.concluida then return jsonb_build_object('erro', 'Esta avaliacao ja foi concluida.'); end if;
    if v.aguardando_nova_chance then return jsonb_build_object('erro', 'Escolha SIM ou NAO para a nova chance antes de enviar.'); end if;

    for q in select value from jsonb_array_elements(coalesce(v.prova->'questoes', '[]'::jsonb))
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

    if v_total = 0 then return jsonb_build_object('erro', 'A prova nao possui questoes.'); end if;
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
        return jsonb_build_object(
            'pode_tentar_novamente', true,
            'nota', v_grade,
            'acertos', v_hits,
            'total_questoes', v_total
        );
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
        created_at = excluded.created_at,
        feedback_professor = '',
        feedback_questoes = '{}'::jsonb,
        feedback_publicado = false,
        feedback_enviado_em = null;

    v_resultado := jsonb_build_object(
        'nota', v_grade,
        'acertos', v_hits::text || '/' || v_total::text,
        'acertos_numero', v_hits,
        'total_questoes', v_total,
        'erros', greatest(v_total - v_hits, 0),
        'tentativas', v.tentativa,
        'detalhes', v_details,
        'respostas', coalesce(p_respostas, '{}'::jsonb),
        'concluida_em', now()
    );

    return jsonb_build_object(
        'pode_tentar_novamente', false,
        'concluida', true,
        'nota', v_grade,
        'acertos', v_hits,
        'total_questoes', v_total,
        'resultado_final', v_resultado
    );
end;
$$;

create or replace function public.encerrar_sem_nova_chance(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v public.provas_alunos%rowtype;
    v_resultado jsonb;
begin
    select * into v
      from public.provas_alunos
     where student_token = p_token
     for update;

    if not found then return jsonb_build_object('erro', 'Prova nao encontrada.'); end if;
    if v.excluida_em is not null then return jsonb_build_object('erro', 'Esta avaliacao foi enviada a lixeira e nao pode mais ser finalizada.'); end if;
    if v.concluida then
        return jsonb_build_object('concluida', true, 'mensagem', 'A avaliacao ja estava concluida.');
    end if;
    if not v.aguardando_nova_chance or v.last_note is null then
        return jsonb_build_object('erro', 'Nao ha resultado pendente para finalizar.');
    end if;

    update public.provas_alunos
       set concluida = true,
           aguardando_nova_chance = false,
           updated_at = now()
     where student_token = p_token;

    insert into public.respostas_avaliacoes (
        student_token, aluno_nome, ano_letivo, serie, bimestre, disciplina,
        acertos, nota, origem, detalhes, respostas, tentativas, historico_tentativas, created_at
    ) values (
        p_token, v.aluno_nome, v.ano_letivo, v.serie, v.bimestre, v.disciplina,
        v.last_hits::text || '/' || v.total_questoes::text, v.last_note,
        'Link Digital Online', coalesce(v.last_details, '[]'::jsonb),
        coalesce(v.last_answers, '{}'::jsonb), v.tentativa,
        coalesce(v.historico_tentativas, '[]'::jsonb), now()
    )
    on conflict (student_token) do update set
        acertos = excluded.acertos,
        nota = excluded.nota,
        origem = excluded.origem,
        detalhes = excluded.detalhes,
        respostas = excluded.respostas,
        tentativas = excluded.tentativas,
        historico_tentativas = excluded.historico_tentativas,
        created_at = excluded.created_at,
        feedback_professor = '',
        feedback_questoes = '{}'::jsonb,
        feedback_publicado = false,
        feedback_enviado_em = null;

    v_resultado := jsonb_build_object(
        'nota', v.last_note,
        'acertos', v.last_hits::text || '/' || v.total_questoes::text,
        'acertos_numero', v.last_hits,
        'total_questoes', v.total_questoes,
        'erros', greatest(v.total_questoes - v.last_hits, 0),
        'tentativas', v.tentativa,
        'detalhes', coalesce(v.last_details, '[]'::jsonb),
        'respostas', coalesce(v.last_answers, '{}'::jsonb),
        'concluida_em', now()
    );

    return jsonb_build_object('concluida', true, 'nota', v.last_note, 'resultado_final', v_resultado);
end;
$$;

revoke all on function public.buscar_prova_aluno(text) from public;
revoke all on function public.finalizar_avaliacao_aluno(text, jsonb) from public;
revoke all on function public.encerrar_sem_nova_chance(text) from public;
grant execute on function public.buscar_prova_aluno(text) to anon, authenticated;
grant execute on function public.finalizar_avaliacao_aluno(text, jsonb) to anon, authenticated;
grant execute on function public.encerrar_sem_nova_chance(text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- Seguranca: as alternativas corretas nunca sao incluidas em 'prova.questoes'.
-- O objeto 'resultado_final' so e devolvido quando a avaliacao esta concluida.
