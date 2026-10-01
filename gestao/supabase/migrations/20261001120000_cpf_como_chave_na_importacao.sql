-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- CPF vira a chave de verdade pra casar gestor na importacao do
-- Sympla, em vez de so e-mail — pedido do organizador em 01/10/2026,
-- depois de um teste criar um gestor duplicado ("GERARDO CARVALHO DA
-- JUNIOR") porque a inscricao usou um e-mail diferente do que ja
-- estava cadastrado pra mesma pessoa ("GERARDO CARVALHO").
--
-- gestores.cpf_norm ja existia desde o baseline (coluna gerada via
-- norm_cpf(cpf)) mas nunca tinha sido usada em lugar nenhum pra casar
-- gente — so e-mail_norm era checado. Essa migration so muda ISSO:
-- se a linha importada tem CPF e ele bate com um gestor que ja
-- existe, usa esse gestor (completando so o que faltava, nunca
-- sobrescrevendo). Sem CPF, ou sem bater, cai no criterio de e-mail
-- de sempre — nada muda pra quem nao tem CPF na planilha.
--
-- Fica so no importador manual (admin.html, upload de planilha). O
-- lado da API (integracao.py, sincronizar_sympla) ganhou o mesmo
-- criterio separadamente, no mesmo commit.
--
-- Nao mexe em admin_vincular_empresas/CNPJ nesta migration — fica
-- pra depois, se o organizador confirmar que quer o mesmo tratamento
-- pro lado de empresas.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION "gestao"."admin_importar_participantes_sympla"(
  "p_evento_slug" "text", "p_linhas" "jsonb"
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
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

    if v_pgto <> 'aprovado' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'nome', v_nome,
        'motivo', 'estado de pagamento nao reconhecido: ' ||
                  coalesce(nullif(v_pgto,''),'(vazio)'));
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
$$;
