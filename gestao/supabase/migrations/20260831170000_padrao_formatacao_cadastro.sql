-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Padrao de formatacao do cadastro (gestores e empresas): caixa alta e
-- validacao de UF — vale pra todo caminho que escreve nessas tabelas,
-- integracao ou manual.
--
-- POR QUE TRIGGER, E NAO REPETIR A LIMPEZA EM CADA FUNCAO
--
-- Contei quantas funcoes inserem ou atualizam gestores hoje: 12 —
-- admin_importar_gestores, admin_importar_participantes_sympla,
-- part_autocadastro (publico, sem login), admin_convidado_avulso,
-- jantar_avulso, checkin_cadastrar, admin_converter_indicacao,
-- admin_aplicar_sugestao, admin_associar_gestor_empresa,
-- admin_fundir_duplicados, admin_vincular_empresas,
-- jantar_importar_convidados_sympla. Repetir "upper(trim(...))" em
-- cada uma e o tipo de coisa que uma funcao nova esquece — foi
-- exatamente assim que o segmento "TECNOLOGIA" (migration anterior)
-- entrou pela porta errada. Trigger BEFORE INSERT/UPDATE cobre as 12
-- de uma vez, e cobre a 13a que ainda nao foi escrita.
--
-- O QUE UNIFORMIZA
--
-- nome, empresa, cargo, cidade: maiuscula, espaco duplo colapsado,
-- borda aparada. "0" (placeholder que a planilha usa no lugar de
-- celula vazia — o mesmo problema ja visto em segmento) vira NULL.
--
-- estado: validado contra as 27 UFs oficiais. Nome por extenso
-- ("GOIÁS", "SÃO PAULO", "DISTRITO FEDERAL"...) e mapeado pro codigo.
-- Sigla de 2 letras que NAO e UF brasileira e mantida como veio —
-- ha pelo menos um caso real na base (SILVIO EBERARDO e DAVIDSON
-- BRITO, cidade "SAN JOSE", estado "CA": California, nao Brasil).
-- Nulificar tudo que nao bate com as 27 destruiria esse dado
-- legitimo. So o que sobra fora de "2 letras" ou "nome de UF
-- reconhecido" vira NULL — nao da pra inventar o que a pessoa quis
-- dizer, e melhor deixar vazio do que gravar lixo.
--
-- segmento entra tambem, chamando o norm_segmento() que ja existe
-- (migration 20260828190000) — mais uma rede de seguranca pros 12
-- caminhos que nunca chamavam essa funcao.
--
-- O QUE NAO MUDA
--
-- email: ja sai sempre minusculo dos importadores hoje (comparacao e
-- por email_norm); nao mexo nisso aqui. telefone, cnpj, linkedin:
-- sem letra que precise de caixa. cidade nao e validada contra lista
-- fechada de municipio (o IBGE tem 5.570 — fora de escopo aqui);
-- so ganha o mesmo tratamento de maiuscula/espaco/zero-vira-null.
--
-- BACKFILL: rodar UPDATE ... SET col = col dispara o BEFORE UPDATE e
-- normaliza tudo que ja esta gravado, na mesma migration que cria a
-- regra — sem duplicar a logica de limpeza numa segunda query.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. TEXTO LIVRE: maiuscula, espaco colapsado, "0" vira NULL
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."padroniza_texto"("p_texto" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  -- string vazia E "0" viram NULL — nullif so pega um valor por vez
  select nullif(nullif(upper(regexp_replace(trim($1), '\s+', ' ', 'g')), ''), '0');
$$;

REVOKE ALL ON FUNCTION "gestao"."padroniza_texto"("text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."padroniza_texto"("text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."padroniza_texto"("text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."padroniza_texto"("text") TO "anon";


-- ---------------------------------------------------------------------
-- 2. ESTADO: as 27 UFs, com nome por extenso mapeado pro codigo
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."norm_uf"("p_texto" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare v_limpo text;
begin
  v_limpo := nullif(upper(trim(coalesce(p_texto,''))), '');
  if v_limpo is null or v_limpo = '0' then
    return null;
  end if;

  -- ja e uma das 27 UFs oficiais — devolve direto
  if v_limpo in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS',
                 'MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC',
                 'SP','SE','TO') then
    return v_limpo;
  end if;

  -- nome por extenso, sem acento — cobre a planilha que as vezes
  -- escreve o estado inteiro em vez da sigla
  case unaccent('unaccent', v_limpo)
    when 'ACRE'                then return 'AC';
    when 'ALAGOAS'             then return 'AL';
    when 'AMAPA'               then return 'AP';
    when 'AMAZONAS'            then return 'AM';
    when 'BAHIA'               then return 'BA';
    when 'CEARA'               then return 'CE';
    when 'DISTRITO FEDERAL'    then return 'DF';
    when 'ESPIRITO SANTO'      then return 'ES';
    when 'GOIAS'               then return 'GO';
    when 'MARANHAO'            then return 'MA';
    when 'MATO GROSSO'         then return 'MT';
    when 'MATO GROSSO DO SUL'  then return 'MS';
    when 'MINAS GERAIS'        then return 'MG';
    when 'PARA'                then return 'PA';
    when 'PARAIBA'             then return 'PB';
    when 'PARANA'              then return 'PR';
    when 'PERNAMBUCO'          then return 'PE';
    when 'PIAUI'               then return 'PI';
    when 'RIO DE JANEIRO'      then return 'RJ';
    when 'RIO GRANDE DO NORTE' then return 'RN';
    when 'RIO GRANDE DO SUL'   then return 'RS';
    when 'RONDONIA'            then return 'RO';
    when 'RORAIMA'             then return 'RR';
    when 'SANTA CATARINA'      then return 'SC';
    when 'SAO PAULO'           then return 'SP';
    when 'SERGIPE'             then return 'SE';
    when 'TOCANTINS'           then return 'TO';
    else null;
  end case;

  -- sobrou algo de 2 letras que nao e UF do Brasil: mantem — pode ser
  -- estado americano ou outra sigla estrangeira legitima (ha caso real
  -- na base: "CA", San Jose). Qualquer outra coisa (nome de cidade
  -- digitado no campo errado, lixo) nao da pra aproveitar.
  if length(v_limpo) = 2 then
    return v_limpo;
  end if;
  return null;
end;
$$;

REVOKE ALL ON FUNCTION "gestao"."norm_uf"("text") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao"."norm_uf"("text") TO "authenticated";
GRANT ALL ON FUNCTION "gestao"."norm_uf"("text") TO "service_role";
GRANT ALL ON FUNCTION "gestao"."norm_uf"("text") TO "anon";


-- ---------------------------------------------------------------------
-- 3. TRIGGER EM GESTORES
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."_normaliza_cadastro_gestor"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.nome     := coalesce(padroniza_texto(new.nome), new.nome);
  new.empresa  := padroniza_texto(new.empresa);
  new.cargo    := padroniza_texto(new.cargo);
  new.cidade   := padroniza_texto(new.cidade);
  new.estado   := norm_uf(new.estado);
  new.segmento := norm_segmento(new.segmento);
  return new;
end;
$$;

DROP TRIGGER IF EXISTS "trg_normaliza_cadastro_gestor" ON "gestao"."gestores";
CREATE TRIGGER "trg_normaliza_cadastro_gestor"
  BEFORE INSERT OR UPDATE ON "gestao"."gestores"
  FOR EACH ROW EXECUTE FUNCTION "gestao"."_normaliza_cadastro_gestor"();


-- ---------------------------------------------------------------------
-- 4. TRIGGER EM EMPRESAS
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "gestao"."_normaliza_cadastro_empresa"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.nome     := coalesce(padroniza_texto(new.nome), new.nome);
  new.cidade   := padroniza_texto(new.cidade);
  new.estado   := norm_uf(new.estado);
  new.segmento := norm_segmento(new.segmento);
  return new;
end;
$$;

DROP TRIGGER IF EXISTS "trg_normaliza_cadastro_empresa" ON "gestao"."empresas";
CREATE TRIGGER "trg_normaliza_cadastro_empresa"
  BEFORE INSERT OR UPDATE ON "gestao"."empresas"
  FOR EACH ROW EXECUTE FUNCTION "gestao"."_normaliza_cadastro_empresa"();


-- ---------------------------------------------------------------------
-- 5. BACKFILL: aplica o padrao em quem ja esta cadastrado
--
-- SET col = col nao muda o dado por si so — so dispara o BEFORE UPDATE
-- acima, que reescreve a coluna pela versao normalizada. Sem where,
-- roda a base inteira; e barato (sao poucas colunas de texto, sem
-- índice pesado envolvido).
-- ---------------------------------------------------------------------
UPDATE "gestao"."gestores" SET
  nome = nome, empresa = empresa, cargo = cargo, cidade = cidade, estado = estado;

UPDATE "gestao"."empresas" SET
  nome = nome, cidade = cidade, estado = estado;


-- ---------------------------------------------------------------------
-- 6. CORRIGE admin_importar_gestores — achado ao testar esta migration
--
-- A migration 20260828190000 (que somou o norm_segmento ao importador)
-- acrescentou `detalhe_erros` e `concluido_em` no UPDATE final de
-- `importacoes`. Nenhuma das duas colunas existe naquela tabela — a
-- tabela tem so id, evento_id, tipo, arquivo, total_linhas, criados,
-- atualizados, erros, executado_por, created_at, do jeito que o
-- baseline (24/08) definiu, sem NENHUM ALTER TABLE depois. Confirmado
-- em producao: a chamada quebra com
-- `column "detalhe_erros" of relation "importacoes" does not exist"`
-- toda vez, desde que 20260828190000 foi ao ar. A importacao que
-- rodou com sucesso nesta mesma sessao (188 criados / 914 atualizados)
-- foi ANTES dessa migration, com a versao de 20260828100000 — ninguem
-- tentou importar planilha depois disso ate este teste.
--
-- O valor `detalhe_erros` continua saindo no retorno da funcao (o
-- front ja mostra a tabela de erro a partir dali); so o UPDATE que
-- tentava persistir na tabela e removido — volta a ser identico ao
-- que 20260825110000 e 20260828100000 sempre fizeram.
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

  -- so as 3 colunas que a tabela realmente tem
  update importacoes set criados = v_criados, atualizados = v_atualizados,
    erros = v_erros
  where id = v_imp;

  return jsonb_build_object('ok', true, 'criados', v_criados,
    'atualizados', v_atualizados, 'sugeridos', v_sugeridos,
    'erros', v_erros, 'detalhe_erros', v_erros_det);
end;
$$;
