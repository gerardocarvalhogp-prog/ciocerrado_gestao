-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Segmento vira lista fechada, e multi-filtro no cadastro de gestores
-- e de empresas.
--
-- O PEDIDO
--
-- "empresas de Goiania, que sao do agro e somente gestores" — tres
-- criterios ao mesmo tempo. Os dois grids so aceitavam um valor por
-- campo, e o de empresas nem isso: so tinha busca por nome.
--
-- Dentro do mesmo campo os valores somam (OU); entre campos eles
-- restringem (E). E o que a frase acima quer dizer.
--
-- ANTES DO FILTRO SERVIR, O SEGMENTO PRECISAVA VIRAR LISTA
--
-- A planilha usa uma lista fechada de 14 segmentos, com codigo na
-- frente para ordenar: "00 - CIO CERRADO", "10 - AGRO", "15 - BANCO",
-- ate "80 - OUTROS". No banco esse campo era texto livre e tinha 27
-- valores distintos. Tres problemas empilhados:
--
-- 1. o codigo as vezes vinha junto e as vezes nao, entao "10 - AGRO"
--    (191) e "AGRO" (4) eram dois itens diferentes na lista suspensa;
-- 2. variacoes de grafia — "Agro", "Saude", "Varejo" com uma linha
--    cada, contra as centenas em maiuscula;
-- 3. 230 gestores com segmento "TECNOLOGIA", que NAO e segmento: e a
--    coluna AREA da planilha, que entrou na coluna errada numa
--    importacao anterior. Na planilha, TECNOLOGIA aparece 901 vezes em
--    AREA e nenhuma em SEGMENTO. Nao e um segmento a mais, e um dado
--    no campo errado.
--
-- Entao o segmento passa a ser tabela (`segmentos`), semeada com as 14
-- linhas exatas da planilha, e o campo do gestor/empresa passa a
-- apontar para ela. Onde da para mapear, mapeia; onde nao da, esvazia.
--
-- O QUE E MAPEADO E O QUE E ESVAZIADO
--
-- Mapeado (a variacao e um caso do item da lista):
--   INDUSTRIA OUTROS, INDUSTRIA FARMACEUTICA  -> INDUSTRIA
--   COMERCIO VAREJISTA E ATACADISTA           -> VAREJO
--   SERVICOS OUTROS, COMUNICACAO E ENTRET.    -> SERVICO
--   TRANSPORTES                               -> TRANSPORTE
--
-- Esvaziado: "0" (nove linhas — e o zero que a planilha usa no lugar
-- de celula vazia) e "TECNOLOGIA" (as 230 acima). Esvaziar um valor
-- comprovadamente do campo errado nao perde informacao; deixa-lo
-- perderia, porque "empresas de tecnologia" passaria a devolver 230
-- empresas de agro, governo e varejo.
--
-- Quem ficou vazio nao fica vazio para sempre: no fim de
-- admin_vincular_empresas, o gestor sem segmento herda o da empresa
-- dele, que por sua vez veio dos colegas. Dois gestores da mesma
-- empresa nao trabalham em segmentos diferentes.
--
-- ATENCAO AS ASSINATURAS
--
-- As funcoes de listagem mudam de assinatura, entao levam DROP antes
-- do CREATE. CREATE OR REPLACE com parametro novo cria uma SEGUNDA
-- funcao, e com duas o PostgREST recusa a chamada inteira ("could not
-- choose the best candidate function").
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. A LISTA
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS "gestao"."segmentos" (
  "codigo" "text" PRIMARY KEY,
  "nome"   "text" NOT NULL UNIQUE,
  "ativo"  boolean NOT NULL DEFAULT true
);

ALTER TABLE "gestao"."segmentos" ENABLE ROW LEVEL SECURITY;

-- Os 14 da planilha, com o codigo que a planilha usa para ordenar.
INSERT INTO "gestao"."segmentos" ("codigo","nome") VALUES
  ('00','CIO CERRADO'), ('10','AGRO'),        ('15','BANCO'),
  ('20','CONSTRUÇÃO'),  ('30','DISTRIBUIÇÃO'),('35','GOVERNO'),
  ('40','HOLDING'),     ('50','INDÚSTRIA'),   ('55','SAÚDE'),
  ('60','SERVIÇO'),     ('65','TRANSPORTE'),  ('66','EDUCAÇÃO'),
  ('70','VAREJO'),      ('80','OUTROS')
ON CONFLICT ("codigo") DO NOTHING;


-- Normaliza um texto qualquer para um nome da lista, ou null se nao
-- houver equivalente. Fica como funcao porque tres lugares precisam da
-- mesma resposta: a limpeza abaixo, o importador e o salvar da empresa.
CREATE OR REPLACE FUNCTION "gestao"."norm_segmento"("p_texto" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_limpo text; v_nome text;
begin
  -- tira o codigo da planilha ("10 - AGRO"), espaco e caixa
  v_limpo := nullif(upper(trim(regexp_replace(
               coalesce(p_texto,''), '^\d+\s*-\s*', ''))), '');
  if v_limpo is null or v_limpo = '0' then
    return null;
  end if;

  -- casa com a lista ignorando acento, que a planilha escreve de dois
  -- jeitos ("SAUDE" e "SAÚDE")
  select s.nome into v_nome from segmentos s
   where unaccent('unaccent', upper(s.nome)) = unaccent('unaccent', v_limpo);
  if v_nome is not null then
    return v_nome;
  end if;

  -- variacoes que sao caso de um item da lista, nao item novo
  return case unaccent('unaccent', v_limpo)
    when 'INDUSTRIA OUTROS'                 then 'INDÚSTRIA'
    when 'INDUSTRIA FARMACEUTICA'           then 'INDÚSTRIA'
    when 'COMERCIO VAREJISTA E ATACADISTA'  then 'VAREJO'
    when 'SERVICOS OUTROS'                  then 'SERVIÇO'
    when 'COMUNICACAO E ENTRETENIMENTO'     then 'SERVIÇO'
    when 'TRANSPORTES'                      then 'TRANSPORTE'
    else null   -- fora da lista: TECNOLOGIA (que e AREA) e afins
  end;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."norm_segmento"("text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."norm_segmento"("text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."norm_segmento"("text") TO "service_role";


UPDATE "gestao"."gestores"
   SET segmento = norm_segmento(segmento)
 WHERE segmento IS DISTINCT FROM norm_segmento(segmento);

UPDATE "gestao"."empresas"
   SET segmento = norm_segmento(segmento)
 WHERE segmento IS DISTINCT FROM norm_segmento(segmento);


CREATE OR REPLACE FUNCTION "gestao"."admin_listar_segmentos"() RETURNS TABLE(
  "codigo" "text", "nome" "text", "qtd_gestores" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select s.codigo, s.nome,
           (select count(*) from gestores g where g.segmento = s.nome)
    from segmentos s where s.ativo order by s.codigo;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_segmentos"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_segmentos"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_segmentos"() TO "service_role";


-- ---------------------------------------------------------------------
-- 2. O IMPORTADOR PASSA A USAR A LISTA
--
-- E a funcao de 20260828100000 inteira; so as linhas do segmento sao
-- novas. Sem isso a proxima planilha recria "10 - AGRO" ao lado de
-- "AGRO" e a lista suspensa volta a ter 27 itens.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_item jsonb;
  v_email text;
  v_empresa_in text;
  v_segmento_in text;
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

    -- tira codigo de planilha colado no nome ("774 - GRUPO X")
    v_empresa_in := nullif(trim(regexp_replace(
                      coalesce(v_item ->> 'empresa',''), '^\d+\s*-\s*', '')), '');

    -- segmento so entra se estiver na lista; fora dela vira null e
    -- espera a heranca da empresa
    v_segmento_in := norm_segmento(v_item ->> 'segmento');

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
                            posicao_gestor, cidade, faturamento, funcionarios,
                            linkedin)
      values (trim(v_item ->> 'nome'), v_email,
              v_empresa_in, nullif(v_item ->> 'cargo',''),
              nullif(v_item ->> 'telefone',''), nullif(v_item ->> 'cnpj',''),
              v_segmento_in, nullif(v_item ->> 'estado',''),
              nullif(v_item ->> 'perfil',''), 'importacao',
              nullif(v_item ->> 'posicao',''), nullif(v_item ->> 'cidade',''),
              nullif(v_item ->> 'faturamento',''), nullif(v_item ->> 'funcionarios',''),
              nullif(v_item ->> 'linkedin',''));
      v_criados := v_criados + 1;
      continue;
    end if;

    v_empresa_nova := v_empresa_in;

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

      if found then v_sugeridos := v_sugeridos + 1; end if;
      v_empresa_nova := null;   -- nao aplica direto; espera aprovacao
    end if;

    update gestores set
      nome = trim(v_item ->> 'nome'),
      empresa = coalesce(v_empresa_nova, empresa),
      cargo = coalesce(nullif(v_item ->> 'cargo',''), cargo),
      telefone = coalesce(nullif(v_item ->> 'telefone',''), telefone),
      cnpj = coalesce(nullif(v_item ->> 'cnpj',''), cnpj),
      segmento = coalesce(v_segmento_in, segmento),
      estado = coalesce(nullif(v_item ->> 'estado',''), estado),
      perfil = coalesce(nullif(v_item ->> 'perfil',''), perfil),
      posicao_gestor = coalesce(nullif(v_item ->> 'posicao',''), posicao_gestor),
      cidade = coalesce(nullif(v_item ->> 'cidade',''), cidade),
      faturamento = coalesce(nullif(v_item ->> 'faturamento',''), faturamento),
      funcionarios = coalesce(nullif(v_item ->> 'funcionarios',''), funcionarios),
      linkedin = coalesce(nullif(v_item ->> 'linkedin',''), linkedin)
    where id = v_id;
    v_atualizados := v_atualizados + 1;
  end loop;

  update importacoes set criados = v_criados, atualizados = v_atualizados,
    erros = v_erros, detalhe_erros = v_erros_det, concluido_em = now()
  where id = v_imp;

  return jsonb_build_object('ok', true, 'criados', v_criados,
    'atualizados', v_atualizados, 'sugeridos', v_sugeridos,
    'erros', v_erros, 'detalhe_erros', v_erros_det);
end;
$$;


-- A empresa tambem so aceita segmento da lista. Se vier algo fora, e
-- erro de digitacao ou tela desatualizada — melhor recusar do que
-- gravar um 15o segmento que ninguem mais vai encontrar no filtro.
CREATE OR REPLACE FUNCTION "gestao"."admin_salvar_empresa"(
  "p_nome" "text",
  "p_id" "uuid" DEFAULT NULL,
  "p_cnpj" "text" DEFAULT NULL,
  "p_site" "text" DEFAULT NULL,
  "p_segmento" "text" DEFAULT NULL,
  "p_cidade" "text" DEFAULT NULL,
  "p_estado" "text" DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v_id uuid; v_seg text;
begin
  perform _exige_staff();

  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da empresa' using errcode='22023';
  end if;

  v_seg := norm_segmento(p_segmento);
  if coalesce(trim(p_segmento),'') <> '' and v_seg is null then
    raise exception 'Segmento "%" nao esta na lista', p_segmento
      using errcode='22023';
  end if;

  if p_id is not null then
    update empresas set
      nome = trim(p_nome), cnpj = nullif(trim(p_cnpj),''),
      site = nullif(trim(p_site),''), segmento = v_seg,
      cidade = nullif(trim(p_cidade),''), estado = nullif(trim(p_estado),'')
    where id = p_id
    returning id into v_id;
    if v_id is null then
      raise exception 'Empresa nao encontrada' using errcode='P0002';
    end if;
  else
    insert into empresas (nome, cnpj, site, segmento, cidade, estado)
    values (trim(p_nome), nullif(trim(p_cnpj),''), nullif(trim(p_site),''),
            v_seg, nullif(trim(p_cidade),''), nullif(trim(p_estado),''))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- ---------------------------------------------------------------------
-- 3. A EMPRESA HERDA DOS GESTORES, E O GESTOR SEM SEGMENTO HERDA DA
--    EMPRESA
--
-- Fica dentro de admin_vincular_empresas porque e o mesmo movimento:
-- toda vez que entra planilha nova, aparecem empresas novas e elas
-- tambem nascem sem esses campos.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."admin_vincular_empresas"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_criadas int := 0; v_vinculados int := 0;
  v_enriquecidas int := 0; v_seg_herdado int := 0;
begin
  perform _exige_admin();

  -- 1. cria as que faltam, uma por nome normalizado. O nome gravado e
  --    a grafia mais frequente na base, nao a primeira encontrada:
  --    "COCA COLA" digitado 40 vezes ganha de "coca cola" digitado 1.
  with nomes as (
    select lower(unaccent('unaccent', regexp_replace(trim(empresa), '\s+', ' ', 'g'))) as chave,
           trim(empresa) as nome, count(*) as n
    from gestores
    where coalesce(trim(empresa),'') <> ''
    group by 1, 2
  ),
  melhor as (
    select distinct on (chave) chave, nome
    from nomes order by chave, n desc, nome
  )
  insert into empresas (nome)
  select m.nome from melhor m
  where not exists (
    select 1 from empresas e
    where lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g'))) = m.chave);
  get diagnostics v_criadas = row_count;

  -- 2. liga quem ainda nao tem vinculo
  update gestores g set empresa_id = e.id
  from empresas e
  where g.empresa_id is null
    and coalesce(trim(g.empresa),'') <> ''
    and lower(unaccent('unaccent', regexp_replace(trim(e.nome), '\s+', ' ', 'g')))
      = lower(unaccent('unaccent', regexp_replace(trim(g.empresa), '\s+', ' ', 'g')));
  get diagnostics v_vinculados = row_count;

  -- 3. a empresa preenche o que esta vazio com o valor mais frequente
  --    entre os gestores dela. mode() ja ignora null, entao o filter e
  --    so para nao contar string vazia. Cada campo e independente: a
  --    empresa pode herdar a cidade e continuar sem segmento.
  --
  --    Nunca sobrescreve — se alguem corrigiu o segmento na mao, a
  --    planilha (que erra o segmento, e sabidamente) nao desfaz.
  with agg as (
    select g.empresa_id as id,
           mode() within group (order by g.segmento)
             filter (where g.segmento is not null)             as segmento,
           mode() within group (order by g.cidade)
             filter (where coalesce(trim(g.cidade),'') <> '')  as cidade,
           mode() within group (order by upper(g.estado))
             filter (where coalesce(trim(g.estado),'') <> '')  as estado
    from gestores g
    where g.empresa_id is not null
    group by g.empresa_id
  )
  update empresas e set
    segmento = coalesce(e.segmento, a.segmento),
    cidade   = coalesce(e.cidade,   a.cidade),
    estado   = coalesce(e.estado,   a.estado)
  from agg a
  where a.id = e.id
    and (e.segmento is null and a.segmento is not null
      or e.cidade   is null and a.cidade   is not null
      or e.estado   is null and a.estado   is not null);
  get diagnostics v_enriquecidas = row_count;

  -- 4. e a volta: quem ficou sem segmento (porque o dele estava no
  --    campo errado) recebe o da propria empresa. Dois gestores da
  --    mesma empresa nao trabalham em segmentos diferentes.
  update gestores g set segmento = e.segmento
  from empresas e
  where g.empresa_id = e.id
    and g.segmento is null
    and e.segmento is not null;
  get diagnostics v_seg_herdado = row_count;

  return jsonb_build_object('ok', true,
    'empresas_criadas', v_criadas, 'gestores_vinculados', v_vinculados,
    'empresas_enriquecidas', v_enriquecidas,
    'gestores_com_segmento_herdado', v_seg_herdado);
end;
$$;


-- ---------------------------------------------------------------------
-- 4. LISTAGEM DE GESTORES COM MULTI-FILTRO
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS "gestao"."admin_listar_gestores"("text","text",integer,integer,"text","text");

CREATE FUNCTION "gestao"."admin_listar_gestores"(
  "p_busca" "text" DEFAULT NULL,
  "p_perfis" "text"[] DEFAULT NULL,
  "p_segmentos" "text"[] DEFAULT NULL,
  "p_estados" "text"[] DEFAULT NULL,
  "p_cidades" "text"[] DEFAULT NULL,
  "p_posicoes" "text"[] DEFAULT NULL,
  "p_com_email" boolean DEFAULT NULL,
  "p_limite" integer DEFAULT 500,
  "p_offset" integer DEFAULT 0
) RETURNS TABLE(
  "id" "uuid", "nome" "text", "email" "text", "empresa" "text",
  "empresa_id" "uuid", "cargo" "text", "telefone" "text", "cidade" "text",
  "estado" "text", "perfil" "text", "linkedin" "text", "segmento" "text",
  "posicao_gestor" "text", "total_geral" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select g.id, g.nome, g.email, g.empresa, g.empresa_id, g.cargo,
           g.telefone, g.cidade, g.estado, g.perfil, g.linkedin, g.segmento,
           g.posicao_gestor,
           count(*) over ()
    from gestores g
    where (p_busca is null or
           unaccent('unaccent', lower(g.nome || ' ' || coalesce(g.empresa,'')))
             like '%' || unaccent('unaccent', lower(p_busca)) || '%')
      -- array vazio conta como "sem filtro": o front manda [] quando o
      -- usuario desmarca tudo, e ali ele quer a base inteira, nao zero
      and (p_perfis is null or cardinality(p_perfis) = 0
           or g.perfil = any(p_perfis))
      and (p_segmentos is null or cardinality(p_segmentos) = 0
           or g.segmento = any(p_segmentos))
      and (p_estados is null or cardinality(p_estados) = 0
           or upper(coalesce(g.estado,'')) = any(
                select upper(x) from unnest(p_estados) x))
      -- cidade e digitada a mao na planilha e vem com e sem acento
      and (p_cidades is null or cardinality(p_cidades) = 0
           or unaccent('unaccent', upper(coalesce(g.cidade,''))) = any(
                select unaccent('unaccent', upper(x)) from unnest(p_cidades) x))
      and (p_posicoes is null or cardinality(p_posicoes) = 0
           or g.posicao_gestor = any(p_posicoes))
      and (p_com_email is null
           or (p_com_email and g.email is not null)
           or (not p_com_email and g.email is null))
    order by g.nome
    limit p_limite offset p_offset;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text"[],"text"[],"text"[],"text"[],"text"[],boolean,integer,integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text"[],"text"[],"text"[],"text"[],"text"[],boolean,integer,integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_gestores"("text","text"[],"text"[],"text"[],"text"[],"text"[],boolean,integer,integer) TO "service_role";


-- Valores distintos para montar os seletores sem lista fixa no HTML —
-- o que existe na base e o que aparece. O <select> de perfil era
-- escrito a mao no admin.html e ja estava incompleto: faltavam
-- TRANSICAO, CLIENTE e OPORTUNIDADE, que existem na base.
CREATE OR REPLACE FUNCTION "gestao"."admin_filtros_gestores"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare v jsonb;
begin
  perform _exige_staff();
  -- devolve valor e contagem: saber que GOVERNO tem 275 e AGRO 191
  -- ajuda a escolher, e denuncia lixo de cadastro com contagem 1
  select jsonb_build_object(
    'perfis',    (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select perfil v, count(*) n from gestores
                           where coalesce(trim(perfil),'') <> '' group by 1) a),
    -- segmento vem da lista, nao do que esta gravado: item sem ninguem
    -- ainda precisa aparecer, senao nunca da para filtrar por ele
    'segmentos', (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by codigo),'[]'::jsonb)
                    from (select s.codigo, s.nome v,
                                 (select count(*) from gestores g
                                   where g.segmento = s.nome) n
                            from segmentos s where s.ativo) b),
    'estados',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select upper(estado) v, count(*) n from gestores
                           where coalesce(trim(estado),'') <> '' group by 1) c),
    'cidades',   (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by n desc, v),'[]'::jsonb)
                    from (select cidade v, count(*) n from gestores
                           where coalesce(trim(cidade),'') <> '' group by 1) d),
    'posicoes',  (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n)
                                            order by v),'[]'::jsonb)
                    from (select posicao_gestor v, count(*) n from gestores
                           where coalesce(trim(posicao_gestor),'') <> '' group by 1) e)
  ) into v;
  return v;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_filtros_gestores"() FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_filtros_gestores"() TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_filtros_gestores"() TO "service_role";


-- ---------------------------------------------------------------------
-- 5. LISTAGEM DE EMPRESAS COM MULTI-FILTRO
--
-- Os campos da empresa podem estar vazios mesmo com os gestores
-- preenchidos (empresa criada agora, antes da heranca rodar). Por isso
-- o filtro casa pela empresa OU por qualquer gestor dela: procurar
-- "Goiania" e nao achar uma empresa cujos cinco gestores sao todos de
-- Goiania seria o filtro mentindo.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS "gestao"."admin_listar_empresas"("text",integer,integer);

CREATE FUNCTION "gestao"."admin_listar_empresas"(
  "p_busca" "text" DEFAULT NULL,
  "p_segmentos" "text"[] DEFAULT NULL,
  "p_cidades" "text"[] DEFAULT NULL,
  "p_estados" "text"[] DEFAULT NULL,
  "p_perfis" "text"[] DEFAULT NULL,
  "p_so_com_gestores" boolean DEFAULT false,
  "p_limite" integer DEFAULT 500,
  "p_offset" integer DEFAULT 0
) RETURNS TABLE(
  "id" "uuid", "nome" "text", "cnpj" "text", "site" "text",
  "segmento" "text", "cidade" "text", "estado" "text",
  "qtd_gestores" bigint, "total_geral" bigint
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    with base as (
      select e.id, e.nome, e.cnpj, e.site, e.segmento, e.cidade, e.estado,
             (select count(*) from gestores g where g.empresa_id = e.id) as qtd
      from empresas e
      where (p_busca is null or
             unaccent('unaccent', lower(e.nome))
               like '%' || unaccent('unaccent', lower(p_busca)) || '%')
        and (p_segmentos is null or cardinality(p_segmentos) = 0
             or e.segmento = any(p_segmentos)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.segmento = any(p_segmentos)))
        and (p_cidades is null or cardinality(p_cidades) = 0
             or unaccent('unaccent', upper(coalesce(e.cidade,''))) = any(
                  select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and unaccent('unaccent', upper(coalesce(g.cidade,''))) = any(
                                 select unaccent('unaccent', upper(x)) from unnest(p_cidades) x)))
        and (p_estados is null or cardinality(p_estados) = 0
             or upper(coalesce(e.estado,'')) = any(select upper(x) from unnest(p_estados) x)
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id
                           and upper(coalesce(g.estado,'')) = any(
                                 select upper(x) from unnest(p_estados) x)))
        -- perfil so existe no gestor: "empresas que tem gestor" e uma
        -- pergunta sobre as pessoas, nao sobre a empresa
        and (p_perfis is null or cardinality(p_perfis) = 0
             or exists (select 1 from gestores g
                         where g.empresa_id = e.id and g.perfil = any(p_perfis)))
    )
    select b.id, b.nome, b.cnpj, b.site, b.segmento, b.cidade, b.estado,
           b.qtd, count(*) over ()
    from base b
    where not p_so_com_gestores or b.qtd > 0
    order by b.nome
    limit p_limite offset p_offset;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."admin_listar_empresas"("text","text"[],"text"[],"text"[],"text"[],boolean,integer,integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."admin_listar_empresas"("text","text"[],"text"[],"text"[],"text"[],boolean,integer,integer) TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."admin_listar_empresas"("text","text"[],"text"[],"text"[],"text"[],boolean,integer,integer) TO "service_role";


-- ---------------------------------------------------------------------
-- 6. MAILING DO JANTAR: SEGMENTO, CIDADE E UF
--
-- O mailing saia com nome, cargo, empresa, e-mail e telefone. Quem
-- recebe a lista pergunta de que segmento e de que praca e cada nome —
-- e essa e exatamente a informacao que a planilha "MAILING JANTARES"
-- antiga trazia. Como o RETURNS TABLE muda, vai DROP antes.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS "gestao"."jantar_convidados_listar"("uuid");

CREATE FUNCTION "gestao"."jantar_convidados_listar"("p_jantar_id" "uuid") RETURNS TABLE(
  "id" "uuid", "gestor_id" "uuid", "nome" "text", "empresa" "text",
  "cargo" "text", "email" "text", "telefone" "text", "origem" "text",
  "rotulo" "text", "score" numeric, "natureza" "text",
  "justificativa" "text", "status" "text",
  "segmento" "text", "cidade" "text", "estado" "text"
)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
begin
  perform _exige_staff();
  return query
    select jc.id, jc.gestor_id, g.nome, coalesce(jc.empresa, g.empresa),
           g.cargo, g.email, g.telefone, jc.origem, jc.rotulo,
           jc.score, jc.natureza, jc.justificativa, jc.status,
           -- o segmento do gestor pode estar vazio; a empresa dele ja
           -- herdou o dos colegas, entao serve de segunda fonte
           coalesce(g.segmento, e.segmento),
           coalesce(g.cidade, e.cidade),
           coalesce(g.estado, e.estado)
    from jantar_convidados jc
    join gestores g on g.id = jc.gestor_id
    left join empresas e on e.id = g.empresa_id
    where jc.jantar_id = p_jantar_id
    order by
      case jc.status when 'compareceu' then 0 when 'confirmado' then 1
                     when 'convidado' then 2 when 'sugerido' then 3 else 4 end,
      g.empresa, g.nome;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."jantar_convidados_listar"("uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."jantar_convidados_listar"("uuid") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."jantar_convidados_listar"("uuid") TO "service_role";
