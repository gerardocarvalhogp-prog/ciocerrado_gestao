-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Gestor sem e-mail vira registro pendente, nao erro de importacao.
--
-- POR QUE
--
-- admin_importar_gestores rejeitava toda linha sem e-mail. Na
-- importacao do CADASTRO 2025 (planilha real, 1100 linhas), 191
-- pessoas (17%) tem nome e empresa mas nao tem e-mail corporativo
-- registrado — dado legitimo, faltando so um campo, nao lixo.
--
-- Descartar essas 191 pessoas do cadastro so porque falta um campo e
-- pior do que guardar o registro incompleto e sanear depois. E o
-- gestor sem e-mail nunca vai conseguir logar (magic link precisa de
-- endereco) — isso e esperado, nao e bug: ele fica "visivel mas sem
-- acesso" ate alguem completar o cadastro.
--
-- POR QUE PRECISA MEXER NA TABELA
--
-- gestores.email era NOT NULL. O indice unico (gestores_email_uk) e
-- em email_norm, nao na coluna email — Postgres aceita quantos NULL
-- forem em coluna com indice unico (nao colide entre si, diferente de
-- string vazia repetida, que colidiria). Por isso a saida e email
-- NULL de verdade, nunca ''.
--
-- Conferido antes de mexer: norm_doc(NULL) devolve NULL (usa
-- coalesce(v,'') por dentro, depois nullif(...,'') desfaz), entao
-- email_norm acompanha sozinho. Nenhuma funcao no schema faz
-- `g.email = algo` esperando erro com NULL — sao todas projecao de
-- leitura ou coalesce, que ja lidam bem com ausencia.
-- =====================================================================

set search_path = gestao, public;

ALTER TABLE "gestao"."gestores" ALTER COLUMN "email" DROP NOT NULL;


CREATE OR REPLACE FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_item jsonb;
  v_email text;
  v_id uuid; v_empresa_ant text; v_cargo_ant text; v_empresa_nova text;
  v_criados int := 0; v_atualizados int := 0; v_erros int := 0;
  v_sugeridos int := 0;
  v_erros_det jsonb := '[]'::jsonb;
  v_imp uuid; v_linha int := 0;
begin
  perform _exige_admin();

  insert into importacoes (tipo, total_linhas, executado_por)
  values ('gestores', jsonb_array_length(coalesce(p_linhas,'[]'::jsonb)),
          auth.jwt() ->> 'email')
  returning id into v_imp;

  for v_item in select * from jsonb_array_elements(coalesce(p_linhas,'[]'::jsonb))
  loop
    v_linha := v_linha + 1;

    if coalesce(trim(v_item ->> 'nome'),'') = '' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'nome vazio',
        'nome', v_item ->> 'nome');
      continue;
    end if;

    -- e-mail e opcional: quem nao tem vira gestor pendente, sem acesso
    -- por magic link ate alguem completar o cadastro. Mas se veio
    -- preenchido, o formato ainda precisa ser valido.
    v_email := nullif(lower(trim(coalesce(v_item ->> 'email',''))), '');
    if v_email is not null
       and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'e-mail invalido: ' || (v_item ->> 'email'),
        'nome', v_item ->> 'nome');
      continue;
    end if;

    -- sem e-mail nao ha como casar com gestor existente por
    -- email_norm — toda linha sem e-mail vira insercao nova. Reimportar
    -- a mesma planilha duplica quem nao tem e-mail; nao ha chave para
    -- deduplicar por nome sozinho sem risco de juntar gente diferente.
    v_id := null;
    if v_email is not null then
      select g.id, g.empresa, g.cargo into v_id, v_empresa_ant, v_cargo_ant
      from gestores g where g.email_norm = norm_doc(v_email);
    end if;

    if v_id is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj,
                            segmento, estado, perfil, origem,
                            posicao_gestor, cidade, faturamento, funcionarios)
      values (trim(v_item ->> 'nome'), v_email,
              nullif(v_item ->> 'empresa',''), nullif(v_item ->> 'cargo',''),
              nullif(v_item ->> 'telefone',''), nullif(v_item ->> 'cnpj',''),
              nullif(v_item ->> 'segmento',''), nullif(v_item ->> 'estado',''),
              nullif(v_item ->> 'perfil',''), 'importacao',
              nullif(v_item ->> 'posicao',''), nullif(v_item ->> 'cidade',''),
              nullif(v_item ->> 'faturamento',''), nullif(v_item ->> 'funcionarios',''));
      v_criados := v_criados + 1;
      continue;
    end if;

    v_empresa_nova := nullif(trim(v_item ->> 'empresa'), '');

    if v_empresa_nova is not null
       and coalesce(trim(v_empresa_ant),'') <> ''
       and lower(unaccent('unaccent', v_empresa_ant))
           <> lower(unaccent('unaccent', v_empresa_nova)) then

      insert into sugestoes_ia (tipo, gestor_id, campo, valor_atual,
                                valor_sugerido, confianca, fonte,
                                justificativa, status)
      select 'troca_empresa', v_id, 'empresa', v_empresa_ant,
             v_empresa_nova, 100, 'importacao de planilha',
             'Linha ' || v_linha || ' da planilha traz empresa diferente da cadastrada',
             'pendente'
      where not exists (
        select 1 from sugestoes_ia s
        where s.gestor_id = v_id and s.campo = 'empresa'
          and s.valor_sugerido = v_empresa_nova and s.status = 'pendente');

      v_sugeridos := v_sugeridos + 1;
    end if;

    if nullif(v_item ->> 'cargo','') is not null
       and lower(coalesce(v_cargo_ant,'')) <> lower(v_item ->> 'cargo') then
      insert into gestores_historico (gestor_id, campo, valor_antigo,
                                      valor_novo, detectado_por)
      values (v_id, 'cargo', v_cargo_ant, v_item ->> 'cargo', 'importacao');
    end if;

    update gestores set
      nome     = coalesce(nullif(v_item ->> 'nome',''), nome),
      empresa  = case when coalesce(trim(empresa),'') = ''
                      then coalesce(v_empresa_nova, empresa) else empresa end,
      cargo    = coalesce(nullif(v_item ->> 'cargo',''), cargo),
      telefone = coalesce(nullif(v_item ->> 'telefone',''), telefone),
      cnpj     = coalesce(nullif(v_item ->> 'cnpj',''), cnpj),
      segmento = coalesce(nullif(v_item ->> 'segmento',''), segmento),
      estado   = coalesce(nullif(v_item ->> 'estado',''), estado),
      perfil   = coalesce(nullif(v_item ->> 'perfil',''), perfil),
      posicao_gestor = coalesce(nullif(v_item ->> 'posicao',''), posicao_gestor),
      cidade   = coalesce(nullif(v_item ->> 'cidade',''), cidade),
      faturamento  = coalesce(nullif(v_item ->> 'faturamento',''), faturamento),
      funcionarios = coalesce(nullif(v_item ->> 'funcionarios',''), funcionarios)
    where id = v_id;

    v_atualizados := v_atualizados + 1;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
                         erros = v_erros
   where id = v_imp;

  return jsonb_build_object('ok', true, 'criados', v_criados,
    'atualizados', v_atualizados, 'erros', v_erros,
    'sugestoes', v_sugeridos, 'detalhe_erros', v_erros_det);
end;
$$;
