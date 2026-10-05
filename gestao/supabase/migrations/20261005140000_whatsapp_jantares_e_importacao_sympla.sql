-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Grupos de WhatsApp dos jantares e importacao do Sympla: quatro
-- consertos.
--
-- Achados dos testes 20 e 23 (05/10/2026), decisao do organizador:
-- corrigir.
--
-- 1. jantar_grupo_obter estourava "column reference status is
--    ambiguous" pra QUALQUER jantar — o retorno declara uma coluna
--    "status" e o subselect que conta confirmados usava "status" sem
--    qualificar. A tela de grupo (jantares.html) nunca carregava.
--
-- 2. _jantar_enfileirar_whatsapp_confirmacao e SECURITY DEFINER, sem
--    guarda de papel, e o comentario de 20260912090000 diz "sem GRANT,
--    nunca exposta" — mas faltou o REVOKE: o Postgres da EXECUTE a
--    PUBLIC por padrao, e anon (a chave publica do site) enfileirava
--    WhatsApp pra qualquer convidado cujo id conhecesse. Fica so pro
--    dono, que e quem roda as funcoes que a chamam.
--
-- 3. jantar_importar_convidados_sympla nao enfileirava o aviso de
--    confirmacao pra convidado NOVO no jantar — o caminho automatico do
--    integracao.py --jantares. O select que le se ele ja existia nao
--    devolve linha quando ele nao existe, v_existia ficava nulo, e
--    "if not (v_existia and ...)" nao entrava.
--
-- 4. As duas importacoes do Sympla (jantar e evento) criavam o gestor na
--    base ANTES de olhar o estado do pagamento: linha recusada
--    ("pendente", estado desconhecido) e cancelamento de quem nem estava
--    no evento deixavam cadastro novo na base de gestores. Agora o
--    pagamento e conferido antes, e cancelado de quem nao existe e so
--    ignorado. Quem ja existe continua sendo atualizado/rebaixado igual.
--
-- 5. norm_telefone_e164 punha o 9 na frente de qualquer numero de 8
--    digitos com DDD — telefone FIXO virava um celular que nao existe,
--    e o aviso ia pro numero errado (o proprio comentario da funcao diz
--    "fixo continua com 8" e "melhor null do que adivinhar"). Agora so
--    numero de celular (comeca com 6, 7, 8 ou 9) ganha o 9; fixo vira
--    nulo — WhatsApp nao chega em fixo de qualquer jeito. A coluna
--    gerada gestores.telefone_e164 e recalculada pra quem mudou.
-- =====================================================================

set search_path = gestao, public;

-- 1 ------------------------------------------------------------------
create or replace function jantar_grupo_obter(p_jantar_id uuid)
returns table(
  status text, invite_link text, erro text,
  solicitado_em timestamptz, criado_em timestamptz, confirmados integer
) language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_confirmados integer;
begin
  perform _exige_staff();

  select count(*)::integer into v_confirmados
    from jantar_convidados jc
   where jc.jantar_id = p_jantar_id and jc.status = 'confirmado';

  return query
    select g.status, g.invite_link, g.erro, g.solicitado_em, g.criado_em, v_confirmados
      from jantar_grupos g where g.jantar_id = p_jantar_id
    union all
    select null::text, null::text, null::text, null::timestamptz, null::timestamptz, v_confirmados
     where not exists (select 1 from jantar_grupos g2 where g2.jantar_id = p_jantar_id)
    limit 1;
end;
$$;

-- 2 ------------------------------------------------------------------
revoke all on function _jantar_enfileirar_whatsapp_confirmacao(uuid) from public, anon, authenticated;

-- 3 e 4 --------------------------------------------------------------
CREATE OR REPLACE FUNCTION gestao.jantar_importar_convidados_sympla(p_jantar_id uuid, p_linhas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_cap int;
  v_item jsonb;
  v_email text; v_nome text; v_pgto text;
  v_gestor uuid; v_linha int := 0;
  v_criados int := 0; v_atualizados int := 0; v_recusados int := 0; v_erros int := 0;
  v_gestores_novos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid;
  v_existia boolean; v_status_atual text; v_jc_id uuid;
begin
  perform _exige_admin();

  select capacidade into v_cap from jantares where id = p_jantar_id;
  if v_cap is null then
    raise exception 'Jantar nao encontrado' using errcode='P0002';
  end if;

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('jantar_convidados_sympla',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    v_nome := nullif(trim(coalesce(v_item ->> 'nome','')), '');
    v_email := nullif(lower(trim(coalesce(
                 nullif(trim(coalesce(v_item ->> 'email_corporativo','')),''),
                 v_item ->> 'email'))), '');
    v_pgto  := lower(trim(coalesce(v_item ->> 'estado_pagamento','')));

    if v_nome is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'linha sem nome');
      continue;
    end if;

    if v_email is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object('linha', v_linha, 'motivo', 'sem e-mail', 'nome', v_nome);
      continue;
    end if;

    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || v_email, 'nome', v_nome);
      continue;
    end if;

    -- pagamento ANTES de tocar na base de gestores: linha que nao vai
    -- virar inscricao (estado desconhecido) nao cria gestor nenhum
    if v_pgto not in ('aprovado','cancelado') then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'nome', v_nome,
        'motivo', 'estado de pagamento nao reconhecido: ' ||
                  coalesce(nullif(v_pgto,''),'(vazio)'));
      continue;
    end if;

    select g.id into v_gestor from gestores g where g.email_norm = norm_doc(v_email);

    -- cancelado de quem nem esta na base: nao ha o que rebaixar, e
    -- cancelamento nao e motivo pra cadastrar ninguem
    if v_gestor is null and v_pgto = 'cancelado' then
      continue;
    end if;

    if v_gestor is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj, cpf, origem)
      values (v_nome, v_email,
              nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), ''),
              nullif(trim(coalesce(v_item ->> 'cargo','')), ''),
              nullif(trim(coalesce(v_item ->> 'telefone','')), ''),
              nullif(trim(coalesce(v_item ->> 'cnpj','')), ''),
              nullif(trim(coalesce(v_item ->> 'cpf','')), ''),
              'importacao')
      returning id into v_gestor;
      v_gestores_novos := v_gestores_novos + 1;
    else
      update gestores set
        empresa  = coalesce(empresa,  nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), '')),
        cargo    = coalesce(cargo,    nullif(trim(coalesce(v_item ->> 'cargo','')), '')),
        telefone = coalesce(telefone, nullif(trim(coalesce(v_item ->> 'telefone','')), '')),
        cnpj     = coalesce(cnpj,     nullif(trim(coalesce(v_item ->> 'cnpj','')), '')),
        cpf      = coalesce(cpf,      nullif(trim(coalesce(v_item ->> 'cpf','')), ''))
      where id = v_gestor;
    end if;

    select exists(select 1 from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor),
           status
      into v_existia, v_status_atual
      from jantar_convidados where jantar_id = p_jantar_id and gestor_id = v_gestor;
    -- convidado ainda fora do jantar: o select acima nao devolve linha e
    -- deixa v_existia NULO — e "not (null and ...)" nao enfileirava o
    -- aviso de quem e novo, justo o caso mais comum
    v_existia := coalesce(v_existia, false);

    if v_pgto = 'cancelado' then
      -- nao cria ninguem por cancelamento; so rebaixa quem ja estava,
      -- e nunca por cima de quem ja compareceu (fato mais forte)
      if v_existia and v_status_atual <> 'compareceu' then
        update jantar_convidados set status = 'recusado', sympla_id = coalesce(
             nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
         where jantar_id = p_jantar_id and gestor_id = v_gestor;
        v_recusados := v_recusados + 1;
      end if;
      continue;
    end if;

    if v_existia and v_status_atual = 'compareceu' then
      -- ja chegou no jantar; so atualiza o rastro do sympla_id, status fica
      update jantar_convidados set
        sympla_id = coalesce(nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''), sympla_id)
      where jantar_id = p_jantar_id and gestor_id = v_gestor;
      v_atualizados := v_atualizados + 1;
      continue;
    end if;

    insert into jantar_convidados (jantar_id, gestor_id, empresa, origem, status, sympla_id)
    select p_jantar_id, v_gestor, g.empresa, 'sympla', 'confirmado',
           nullif(trim(coalesce(v_item ->> 'sympla_id','')), '')
      from gestores g where g.id = v_gestor
    on conflict (jantar_id, gestor_id) do update set
      status    = 'confirmado',
      sympla_id = coalesce(excluded.sympla_id, jantar_convidados.sympla_id)
    returning id into v_jc_id;

    -- so enfileira quando a linha REALMENTE entrou confirmada agora —
    -- v_existia+status ja lido antes do upsert acima, mesmo raciocinio
    -- do guard em jantar_marcar_convidado
    if not (v_existia and v_status_atual = 'confirmado') then
      perform _jantar_enfileirar_whatsapp_confirmacao(v_jc_id);
    end if;

    if v_existia then v_atualizados := v_atualizados + 1;
    else                 v_criados := v_criados + 1;
    end if;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object(
    'ok', true,
    'criados', v_criados,
    'atualizados', v_atualizados,
    'recusados', v_recusados,
    'gestores_novos', v_gestores_novos,
    'erros', v_erros,
    'detalhe_erros', v_erros_det,
    'capacidade', v_cap,
    'ocupados_agora', (select count(*) from jantar_convidados
                        where jantar_id = p_jantar_id and status in ('confirmado','compareceu')));
end;
$function$;

CREATE OR REPLACE FUNCTION gestao.admin_importar_participantes_sympla(p_evento_slug text, p_linhas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
declare
  v_evento uuid;
  v_item jsonb;
  v_email text; v_nome text; v_pgto text; v_cpf text;
  v_gestor uuid; v_linha int := 0;
  v_criados int := 0;      -- participantes novos
  v_atualizados int := 0;  -- ja existiam neste evento
  v_cancelados int := 0;
  v_erros int := 0;
  v_gestores_novos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid;
  v_existia boolean;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento "%" nao encontrado', p_evento_slug using errcode='P0002';
  end if;

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('participantes_sympla',
          jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;
    -- precisa resetar aqui: o select por CPF so roda "if v_cpf is not
    -- null" — numa linha sem CPF esse select nem executa, e sem isso
    -- v_gestor ficaria com o id da pessoa da iteracao anterior
    v_gestor := null;

    v_nome := nullif(trim(coalesce(v_item ->> 'nome','')), '');
    -- corporativo primeiro: e ele que casa com a base ja cadastrada
    v_email := nullif(lower(trim(coalesce(
                 nullif(trim(coalesce(v_item ->> 'email_corporativo','')),''),
                 v_item ->> 'email'))), '');
    v_pgto  := lower(trim(coalesce(v_item ->> 'estado_pagamento','')));
    v_cpf   := nullif(regexp_replace(coalesce(v_item ->> 'cpf',''), '[^0-9]', '', 'g'), '');

    if v_nome is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'linha sem nome');
      continue;
    end if;

    if v_email is null then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'sem e-mail', 'nome', v_nome);
      continue;
    end if;

    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || v_email, 'nome', v_nome);
      continue;
    end if;

    -- pagamento ANTES de tocar na base de gestores: linha que nao vai
    -- virar inscricao (estado desconhecido) nao cria gestor nenhum
    if v_pgto not in ('aprovado','cancelado') then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'nome', v_nome,
        'motivo', 'estado de pagamento nao reconhecido: ' ||
                  coalesce(nullif(v_pgto,''),'(vazio)'));
      continue;
    end if;

    -- 1. gestor (base geral) — CPF e a chave de verdade quando a
    --    planilha traz ele: e-mail pode mudar entre inscricoes da
    --    mesma pessoa (pessoal numa, corporativo noutra), CPF nao.
    --    Sem CPF (ou sem bater), cai no criterio de e-mail de sempre.
    if v_cpf is not null then
      select g.id into v_gestor from gestores g where g.cpf_norm = v_cpf;
    end if;

    if v_gestor is null then
      select g.id into v_gestor from gestores g where g.email_norm = norm_doc(v_email);
    end if;

    -- cancelado de quem nem esta na base: nao ha o que rebaixar, e
    -- cancelamento nao e motivo pra cadastrar ninguem
    if v_gestor is null and v_pgto = 'cancelado' then
      continue;
    end if;

    if v_gestor is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj, cpf, origem)
      values (v_nome, v_email,
              nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), ''),
              nullif(trim(coalesce(v_item ->> 'cargo','')), ''),
              nullif(trim(coalesce(v_item ->> 'telefone','')), ''),
              nullif(trim(coalesce(v_item ->> 'cnpj','')), ''),
              nullif(trim(coalesce(v_item ->> 'cpf','')), ''),
              -- gestores.origem nao aceita 'sympla' (so manual,
              -- importacao, ia, autocadastro, indicacao) e nao vale
              -- mexer na constraint por isso: o gestor veio mesmo de
              -- uma importacao. Que a inscricao daquele evento veio do
              -- Sympla fica em participantes.origem, que e onde a
              -- distincao importa.
              'importacao')
      returning id into v_gestor;
      v_gestores_novos := v_gestores_novos + 1;
    else
      -- so preenche buraco; nao sobrescreve o que a organizacao ja
      -- curou na base (mesma regra do importador de gestores) — vale
      -- pro email tambem: achou por CPF com e-mail diferente, o
      -- e-mail que ja estava cadastrado continua valendo
      update gestores set
        email    = coalesce(email,    v_email),
        empresa  = coalesce(empresa,  nullif(trim(regexp_replace(coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), '')),
        cargo    = coalesce(cargo,    nullif(trim(coalesce(v_item ->> 'cargo','')), '')),
        telefone = coalesce(telefone, nullif(trim(coalesce(v_item ->> 'telefone','')), '')),
        cnpj     = coalesce(cnpj,     nullif(trim(coalesce(v_item ->> 'cnpj','')), '')),
        cpf      = coalesce(cpf,      nullif(trim(coalesce(v_item ->> 'cpf','')), ''))
      where id = v_gestor;
    end if;

    select exists(select 1 from participantes
                   where evento_id = v_evento and gestor_id = v_gestor)
      into v_existia;

    -- 2. participante do evento
    if v_pgto = 'cancelado' then
      -- nao cria ninguem por cancelamento; so reflete em quem ja existia,
      -- senao um cancelado antigo continuaria aprovado no check-in
      if v_existia then
        update participantes set status = 'cancelado'
         where evento_id = v_evento and gestor_id = v_gestor;
        v_cancelados := v_cancelados + 1;
      end if;
      continue;
    end if;

    insert into participantes (evento_id, gestor_id, status, origem,
                               sympla_id, tipo_ingresso, aprovado_em, aprovado_por)
    values (v_evento, v_gestor, 'aprovado', 'sympla',
            nullif(trim(coalesce(v_item ->> 'sympla_id','')), ''),
            nullif(trim(coalesce(v_item ->> 'tipo_ingresso','')), ''),
            now(), auth.jwt() ->> 'email')
    on conflict (evento_id, gestor_id) do update set
      status        = 'aprovado',
      sympla_id     = coalesce(excluded.sympla_id, participantes.sympla_id),
      tipo_ingresso = coalesce(excluded.tipo_ingresso, participantes.tipo_ingresso),
      aprovado_em   = coalesce(participantes.aprovado_em, excluded.aprovado_em);

    if v_existia then v_atualizados := v_atualizados + 1;
    else                 v_criados := v_criados + 1;
    end if;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object(
    'ok', true,
    'criados', v_criados,
    'atualizados', v_atualizados,
    'cancelados', v_cancelados,
    'gestores_novos', v_gestores_novos,
    'erros', v_erros,
    'detalhe_erros', v_erros_det);
end;
$function$;

-- 5 ------------------------------------------------------------------
create or replace function norm_telefone_e164(v text) returns text
language sql immutable as $$
  select case
    -- DDD + 8 digitos: celular antigo (sem o 9) ganha o 9; fixo vira null
    when length(d) = 10 and substring(d,3,1) in ('6','7','8','9')
      then '55' || substring(d,1,2) || '9' || substring(d,3)
    when length(d) = 11 then '55' || d                                          -- DDD + 9 digitos
    when length(d) = 12 and left(d,2) = '55' and substring(d,5,1) in ('6','7','8','9')
      then d                                                                    -- 55 + DDD + 8, celular
    when length(d) = 13 and left(d,2) = '55' then d                             -- ja tem 55 + 9 digitos
    else null
  end
  from (select regexp_replace(coalesce(v,''), '\D', '', 'g') as d) x;
$$;

-- coluna gerada so recalcula quando a linha e atualizada
update gestores set telefone = telefone
 where telefone_e164 is distinct from norm_telefone_e164(telefone);
