-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Mesmo tratamento do CPF (migration 20261001120000), agora pro lado
-- de empresa: CNPJ vira a chave de verdade pra casar/evitar duplicata,
-- em vez de so o nome normalizado. Pedido do organizador em
-- 01/10/2026, na sequencia direta do caso do CPF.
--
-- Diferente de gestores.cpf_norm (que ja existia desde o baseline),
-- nao havia nenhuma normalizacao de CNPJ ainda — cria norm_cnpj() e
-- as colunas geradas cnpj_norm em empresas e gestores (mesmo padrao
-- de email_norm/cpf_norm: coluna gerada, so digitos).
--
-- Dois lugares casavam empresa so por nome, e passam a tentar CNPJ
-- primeiro:
--
-- 1. admin_vincular_empresas() — liga gestores.empresa (texto livre)
--    a um registro em empresas. Ganha um passo 0, antes do de sempre:
--    gestor com CNPJ que bate com uma empresa existente liga direto,
--    nome digitado diferente ("Grupo X" vs "X Comercio Ltda") nao
--    impede mais o vinculo nem cria empresa duplicada.
--
-- 2. admin_salvar_patrocinador() — resolve a empresa do patrocinador
--    ao salvar no admin.html. CNPJ bate primeiro; sem bater (ou sem
--    CNPJ informado), cai no casamento por nome de sempre.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. NORMALIZACAO
-- ---------------------------------------------------------------------
create or replace function norm_cnpj(v text) returns text
language sql immutable as $$
  select nullif(regexp_replace(coalesce(v,''), '[^0-9]', '', 'g'), '');
$$;

revoke execute on function norm_cnpj(text) from public, anon;
grant execute on function norm_cnpj(text) to authenticated, service_role;

alter table empresas add column if not exists cnpj_norm text
  generated always as (norm_cnpj(cnpj)) stored;
alter table gestores add column if not exists cnpj_norm text
  generated always as (norm_cnpj(cnpj)) stored;

-- ---------------------------------------------------------------------
-- 2. LIGAR GESTOR A EMPRESA: CNPJ PRIMEIRO, NOME DEPOIS
-- ---------------------------------------------------------------------
create or replace function admin_vincular_empresas() returns jsonb
language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_criadas int := 0;
  v_vinculados_cnpj int := 0;
  v_vinculados_nome int := 0;
begin
  perform _exige_admin();

  -- 0. CNPJ e a chave de verdade quando disponivel: liga direto, antes
  --    de qualquer coisa por nome.
  update gestores g set empresa_id = e.id
  from empresas e
  where g.empresa_id is null
    and g.cnpj_norm is not null
    and e.cnpj_norm = g.cnpj_norm;
  get diagnostics v_vinculados_cnpj = row_count;

  -- 1. cria as que faltam, uma por nome normalizado, pro que sobrou
  --    sem vinculo (nao recriar o que o passo 0 ja resolveu). O nome
  --    gravado e a grafia mais frequente na base, nao a primeira
  --    encontrada: "COCA COLA" digitado 40 vezes ganha de "coca cola"
  --    digitado 1. Carrega tambem um CNPJ representante do grupo,
  --    quando algum gestor daquele nome tiver informado.
  with nomes as (
    select lower(unaccent('unaccent', regexp_replace(trim(empresa), '\s+', ' ', 'g'))) as chave,
           trim(empresa) as nome, count(*) as n,
           (array_agg(cnpj) filter (where cnpj is not null))[1] as cnpj_representante
    from gestores
    where coalesce(trim(empresa),'') <> '' and empresa_id is null
    group by 1, 2
  ),
  melhor as (
    select distinct on (chave) chave, nome, cnpj_representante
    from nomes order by chave, n desc, nome
  )
  insert into empresas (nome, cnpj)
  select m.nome, m.cnpj_representante from melhor m
  where not exists (
    select 1 from empresas e
    where lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g'))) = m.chave);
  get diagnostics v_criadas = row_count;

  -- 2. liga quem ainda nao tem vinculo, por nome (criterio de sempre)
  update gestores g set empresa_id = e.id
  from empresas e
  where g.empresa_id is null
    and coalesce(trim(g.empresa),'') <> ''
    and lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g')))
      = lower(unaccent('unaccent', regexp_replace(trim(g.empresa), '\s+', ' ', 'g')));
  get diagnostics v_vinculados_nome = row_count;

  return jsonb_build_object('ok', true,
    'empresas_criadas', v_criadas,
    'gestores_vinculados_por_cnpj', v_vinculados_cnpj,
    'gestores_vinculados_por_nome', v_vinculados_nome);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. CADASTRAR/ATUALIZAR PATROCINADOR: CNPJ PRIMEIRO, NOME DEPOIS
-- ---------------------------------------------------------------------
create or replace function admin_salvar_patrocinador(
  p_evento_slug text, p_empresa text,
  p_cota_nome text DEFAULT NULL::text,
  p_cnpj text DEFAULT NULL::text,
  p_segmento text DEFAULT NULL::text,
  p_o_que_vende text DEFAULT NULL::text,
  p_quartos_extras integer DEFAULT 0,
  p_vagas_mesa_override integer DEFAULT NULL::integer,
  p_status text DEFAULT 'ativo'::text,
  p_site text DEFAULT NULL::text,
  p_resumo text DEFAULT NULL::text,
  p_natureza text DEFAULT NULL::text,
  p_cidade text DEFAULT NULL::text,
  p_estado text DEFAULT NULL::text,
  p_lounge text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare v_evento uuid; v_cota uuid; v_id uuid; v_empresa uuid; v_tem_cota boolean;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_empresa),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  if p_cota_nome is not null and trim(p_cota_nome) <> '' then
    select id into v_cota from cotas
     where evento_id = v_evento and lower(nome) = lower(trim(p_cota_nome));
    if v_cota is null then
      raise exception 'Cota "%" nao existe neste evento', p_cota_nome
        using errcode='P0002';
    end if;
  end if;

  -- resolve a empresa (cadastro unico): CNPJ e a chave de verdade
  -- quando informado — nome digitado diferente do que ja esta na base
  -- ("Grupo X" vs "X Comercio Ltda") nao deveria criar uma segunda
  -- empresa pro mesmo CNPJ. Sem CNPJ, ou sem bater, cai no casamento
  -- por nome de sempre.
  if norm_cnpj(p_cnpj) is not null then
    select id into v_empresa from empresas where cnpj_norm = norm_cnpj(p_cnpj);
  end if;

  if v_empresa is null then
    select id into v_empresa from empresas where lower(trim(nome)) = lower(trim(p_empresa));
  end if;

  if v_empresa is null then
    insert into empresas (nome, cnpj, segmento, site, cidade, estado, resumo, o_que_vende, natureza)
    values (trim(p_empresa), p_cnpj, p_segmento, p_site, p_cidade, p_estado,
            p_resumo, p_o_que_vende, p_natureza)
    returning id into v_empresa;
  else
    update empresas set
      nome        = trim(p_empresa),
      cnpj        = coalesce(p_cnpj, empresas.cnpj),
      segmento    = coalesce(p_segmento, empresas.segmento),
      site        = coalesce(p_site, empresas.site),
      cidade      = coalesce(p_cidade, empresas.cidade),
      estado      = coalesce(p_estado, empresas.estado),
      resumo      = coalesce(p_resumo, empresas.resumo),
      o_que_vende = coalesce(p_o_que_vende, empresas.o_que_vende),
      natureza    = coalesce(p_natureza, empresas.natureza)
    where id = v_empresa;
  end if;

  insert into patrocinadores (evento_id, empresa_id, cota_id, empresa, cnpj, segmento,
                              o_que_vende, quartos_extras_cota,
                              vagas_mesa_override, status,
                              site, resumo, natureza, cidade, estado, lounge)
  values (v_evento, v_empresa, v_cota, trim(p_empresa), p_cnpj, p_segmento,
          p_o_que_vende, coalesce(p_quartos_extras,0),
          p_vagas_mesa_override, p_status,
          p_site, p_resumo, p_natureza, p_cidade, p_estado,
          nullif(trim(p_lounge),''))
  on conflict (evento_id, empresa_id) do update set
    cota_id = coalesce(excluded.cota_id, patrocinadores.cota_id),
    empresa = excluded.empresa,
    cnpj = coalesce(excluded.cnpj, patrocinadores.cnpj),
    segmento = coalesce(excluded.segmento, patrocinadores.segmento),
    o_que_vende = coalesce(excluded.o_que_vende, patrocinadores.o_que_vende),
    quartos_extras_cota = excluded.quartos_extras_cota,
    vagas_mesa_override = excluded.vagas_mesa_override,
    status = excluded.status,
    site = coalesce(excluded.site, patrocinadores.site),
    resumo = coalesce(excluded.resumo, patrocinadores.resumo),
    natureza = coalesce(excluded.natureza, patrocinadores.natureza),
    cidade = coalesce(excluded.cidade, patrocinadores.cidade),
    estado = coalesce(excluded.estado, patrocinadores.estado),
    lounge = coalesce(excluded.lounge, patrocinadores.lounge)
  returning id into v_id;

  if v_id is not null and coalesce(p_status,'ativo') = 'ativo' then
    select cota_id is not null into v_tem_cota from patrocinadores where id = v_id;
    if v_tem_cota then
      perform admin_gerar_quartos_cota(v_id);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'empresa_id', v_empresa);
end;
$$;
