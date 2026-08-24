-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- correcoes-01.sql  ·  bugs do relatorio de QA de 18/08/2026
--
-- Rodar DEPOIS de migracao-03.sql.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. 🔴 "column reference id is ambiguous" ao abrir um quarto
--
-- Causa: em plpgsql, as colunas declaradas em RETURNS TABLE viram
-- variaveis dentro da funcao. Como havia uma coluna de saida chamada
-- "id", o "where id = p_reserva_id" ficou ambiguo entre essa variavel e
-- a coluna reservas.id. O Postgres nao adivinha e recusa a consulta.
--
-- Correcao: qualificar com o alias da tabela. Aproveitei para renomear
-- a coluna de saida para ocupante_id, que e mais claro e evita o
-- problema voltar em qualquer edicao futura.
-- =====================================================================

drop function if exists patro_listar_ocupantes(uuid);

create or replace function patro_listar_ocupantes(p_reserva_id uuid)
returns table (
  ocupante_id uuid, nome text, cpf text, data_nascimento date,
  tipo text, usa_transfer boolean, email text, telefone text
) language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_patro uuid;
begin
  select r.patrocinador_id into v_patro
  from reservas r where r.id = p_reserva_id;

  perform _exige_patrocinador(v_patro);

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento,
           o.tipo, o.usa_transfer, o.email, o.telefone
    from ocupantes o where o.reserva_id = p_reserva_id
    order by o.created_at;
end;
$$;

-- =====================================================================
-- 2. 🔴 Importacao trocava a empresa sem passar pela fila de revisao
--
-- A tela promete "nada e aplicado sem sua aprovacao", mas a importacao
-- sobrescrevia a empresa direto. Uma planilha errada trocava o cadastro
-- de todo mundo sem chance de conferir.
--
-- Agora: campos comuns continuam sendo atualizados direto (telefone,
-- cargo, segmento...), mas TROCA DE EMPRESA vira sugestao pendente.
-- Empresa vazia no cadastro nao conta como troca — e preenchimento.
-- =====================================================================

create or replace function admin_importar_gestores(p_linhas jsonb)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_item jsonb;
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

    if coalesce(trim(v_item ->> 'email'),'') = ''
       or coalesce(trim(v_item ->> 'nome'),'') = '' then
      v_erros := v_erros + 1;
      v_erros_det := v_erros_det || jsonb_build_object(
        'linha', v_linha, 'motivo', 'nome ou e-mail vazio',
        'nome', v_item ->> 'nome');
      continue;
    end if;

    select g.id, g.empresa, g.cargo into v_id, v_empresa_ant, v_cargo_ant
    from gestores g where g.email_norm = norm_doc(v_item ->> 'email');

    if v_id is null then
      insert into gestores (nome, email, empresa, cargo, telefone, cnpj,
                            segmento, estado, perfil, origem)
      values (trim(v_item ->> 'nome'), lower(trim(v_item ->> 'email')),
              nullif(v_item ->> 'empresa',''), nullif(v_item ->> 'cargo',''),
              nullif(v_item ->> 'telefone',''), nullif(v_item ->> 'cnpj',''),
              nullif(v_item ->> 'segmento',''), nullif(v_item ->> 'estado',''),
              nullif(v_item ->> 'perfil',''), 'importacao');
      v_criados := v_criados + 1;
      continue;
    end if;

    v_empresa_nova := nullif(trim(v_item ->> 'empresa'), '');

    -- TROCA de empresa (havia uma antes e veio outra) vai para a fila.
    -- Preencher empresa que estava vazia nao e troca, aplica direto.
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
      -- nao empilha a mesma sugestao a cada reimportacao do arquivo
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
      -- empresa so entra quando estava vazia; troca espera aprovacao
      empresa  = case when coalesce(trim(empresa),'') = ''
                      then coalesce(v_empresa_nova, empresa) else empresa end,
      cargo    = coalesce(nullif(v_item ->> 'cargo',''), cargo),
      telefone = coalesce(nullif(v_item ->> 'telefone',''), telefone),
      cnpj     = coalesce(nullif(v_item ->> 'cnpj',''), cnpj),
      segmento = coalesce(nullif(v_item ->> 'segmento',''), segmento),
      estado   = coalesce(nullif(v_item ->> 'estado',''), estado),
      perfil   = coalesce(nullif(v_item ->> 'perfil',''), perfil)
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

-- =====================================================================
-- 3. ⚠️ Match sugeria quem ja estava confirmado na sessao
--
-- A exclusao estava fixa em tipo = 'jantar'. Numa sessao de mesa
-- redonda, ninguem era excluido; e mesmo no jantar, quem tinha acabado
-- de ser adicionado continuava aparecendo na lista de sugestoes.
-- Agora usa o tipo da propria sessao e exclui tambem quem ja esta
-- confirmado nela.
-- =====================================================================

create or replace function admin_match_jantar(
  p_sessao_id uuid,
  p_limite int default 20
) returns table (
  participante_id uuid, nome text, empresa text, segmento text,
  faturamento text, aderencia numeric
) language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_patro_seg text; v_vende text; v_tipo text;
begin
  perform _exige_staff();

  select s.evento_id, s.tipo, p.segmento, p.o_que_vende
    into v_evento, v_tipo, v_patro_seg, v_vende
  from sessoes s join patrocinadores p on p.id = s.patrocinador_id
  where s.id = p_sessao_id;

  return query
    select pa.id, g.nome, g.empresa, g.segmento, pp.faturamento,
      round(
        (case when v_patro_seg is not null
               and lower(coalesce(g.segmento,'')) = lower(v_patro_seg)
              then 50 else 0 end)
        + (case when v_vende is not null
                 and coalesce(pp.respostas::text,'') ilike '%' || v_vende || '%'
                then 30 else 0 end)
        + (case when pp.faturamento ilike '%bilh%' then 20
                when pp.faturamento ilike '%milh%' then 10
                else 0 end)
      , 2)::numeric as aderencia
    from participantes pa
    join gestores g on g.id = pa.gestor_id
    left join participante_perfil pp on pp.participante_id = pa.id
    where pa.evento_id = v_evento
      and pa.status = 'aprovado'
      -- fora quem ja esta em qualquer sessao DESTE tipo, inclusive esta
      and not exists (
        select 1 from sessao_convidados sc
        join sessoes s3 on s3.id = sc.sessao_id
        where sc.participante_id = pa.id and sc.status = 'confirmado'
          and s3.evento_id = v_evento and s3.tipo = v_tipo)
    order by aderencia desc, g.empresa
    limit p_limite;
end;
$$;

-- =====================================================================
-- 4. ⚠️ Sessao encerrada nao distinguia "escolheu" de "passou a vez"
-- =====================================================================

drop function if exists patro_minhas_sessoes(uuid);

create or replace function patro_minhas_sessoes(p_patrocinador_id uuid)
returns table (
  sessao_id uuid, tipo text, data date, horario time, local text,
  vagas int, escolhidos bigint, encerrada boolean, passou boolean
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select s.id, s.tipo, s.data, s.horario, s.local, s.vagas,
           (select count(*) from sessao_convidados sc
             where sc.sessao_id = s.id and sc.status = 'confirmado'),
           (s.escolha_encerrada_em is not null or s.passou_em is not null),
           (s.passou_em is not null)
    from sessoes s
    where s.patrocinador_id = p_patrocinador_id
    order by s.tipo, s.data, s.horario;
end;
$$;

-- =====================================================================
-- 5. ⚠️ Usuario ligado a mais de um patrocinador
--
-- O portal pegava silenciosamente o primeiro da lista. Passa a devolver
-- a contagem, para a tela avisar em vez de escolher sozinha.
-- =====================================================================

drop function if exists patro_meu_painel(text);

create or replace function patro_meu_painel(p_evento_slug text)
returns table (
  patrocinador_id     uuid,
  empresa             text,
  cota                text,
  quartos_incluidos   int,
  tipo_quarto_padrao  text,
  vagas_mesa_redonda  int,
  tem_reuniao_exclusiva boolean,
  tem_jantar          boolean,
  quartos_preenchidos int,
  quartos_total       int,
  indicacoes_feitas   int,
  fechado             boolean,
  quantas_empresas    bigint
) language sql stable security definer
set search_path = gestao, public as $$
  select
    p.id, p.empresa, c.nome,
    coalesce((select sum(cq.quantidade)::int from cota_quartos cq
              where cq.cota_id = c.id), 0),
    c.tipo_quarto_padrao,
    coalesce(p.vagas_mesa_override, c.vagas_mesa_redonda),
    c.tem_reuniao_exclusiva,
    c.tem_jantar,
    (select count(*)::int from reservas r
      where r.patrocinador_id = p.id and r.status = 'completo'),
    (select count(*)::int from reservas r
      where r.patrocinador_id = p.id and r.status <> 'cancelado'),
    (select count(*)::int from indicacoes i where i.patrocinador_id = p.id),
    p.fechado_em is not null,
    count(*) over ()
  from patrocinadores p
  join eventos e on e.id = p.evento_id
  join cotas   c on c.id = p.cota_id
  where e.slug = p_evento_slug
    and p.status = 'ativo'
    and p.id in (select meus_patrocinadores())
  order by p.empresa;
$$;

grant execute on function
  patro_listar_ocupantes(uuid),
  admin_importar_gestores(jsonb),
  admin_match_jantar(uuid, int),
  patro_minhas_sessoes(uuid),
  patro_meu_painel(text)
to authenticated;
