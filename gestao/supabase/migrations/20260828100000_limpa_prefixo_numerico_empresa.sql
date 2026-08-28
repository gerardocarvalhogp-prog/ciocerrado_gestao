-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Tira o codigo interno da planilha do nome da empresa.
--
-- O QUE ACONTECEU
--
-- Na importacao dos perfis de LinkedIn (25/08) eu resolvi o "id da
-- empresa" da planilha modelo-importacao-usuario.xlsx cruzando com a
-- aba Planilha3 — e mandei para o banco o rotulo INTEIRO daquela aba,
-- que vinha no formato "774 - GRUPO JOSE ALVES". O numero e codigo
-- interno da planilha, nao faz parte do nome.
--
-- Resultado medido em producao: 92 gestores com empresa assim.
-- Efeito pratico: "774 - GRUPO JOSE ALVES" e "GRUPO JOSE ALVES" viram
-- duas empresas diferentes em toda busca, filtro e agrupamento — e a
-- deteccao de troca de empresa da importacao passa a gerar sugestao
-- falsa toda vez que a mesma pessoa vier de outra planilha.
--
-- O CONSERTO
--
-- Duas frentes: limpa o que ja entrou, e normaliza na porta de entrada
-- para nao depender de quem monta a planilha da proxima vez.
--
-- O padrao "^digitos espaco-opcional hifen espaco-opcional" no INICIO
-- do nome e sempre artefato de planilha — nome de empresa de verdade
-- nao comeca com "774 - ". Empresas com numero no nome legitimo
-- ("3M", "99", "Grupo 3 Coracoes") nao casam: falta o hifen separador.
-- =====================================================================

set search_path = gestao, public;

UPDATE gestores
   SET empresa = nullif(trim(regexp_replace(empresa, '^\d+\s*-\s*', '')), '')
 WHERE empresa ~ '^\d+\s*-\s*';

-- Mesma limpeza em empresas (tabela nova, hoje vazia em producao — mas
-- se alguem importar por ali no futuro, vale a mesma regra).
UPDATE empresas
   SET nome = trim(regexp_replace(nome, '^\d+\s*-\s*', ''))
 WHERE nome ~ '^\d+\s*-\s*';


-- Porta de entrada: mesma normalizacao dentro do importador, para o
-- proximo arquivo com codigo colado no nome nao sujar a base de novo.
CREATE OR REPLACE FUNCTION "gestao"."admin_importar_gestores"("p_linhas" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao', 'public'
    AS $$
declare
  v_item jsonb;
  v_email text;
  v_empresa_in text;
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
              nullif(v_item ->> 'segmento',''), nullif(v_item ->> 'estado',''),
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
      funcionarios = coalesce(nullif(v_item ->> 'funcionarios',''), funcionarios),
      linkedin     = coalesce(nullif(v_item ->> 'linkedin',''), linkedin)
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
