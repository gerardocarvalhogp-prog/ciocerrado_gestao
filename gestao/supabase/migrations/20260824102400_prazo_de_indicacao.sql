-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Indicacao vira RESERVA, com prazo por cota.
--
-- A REGRA (definida pelo organizador em 24/08/2026)
--
-- A fila de escolha ja era por cota: Esmeralda, Diamante, Platina,
-- Ouro, Prata, e dentro da cota quem fechou primeiro. O que faltava era
-- o que acontece com quem a empresa indicou no PERFIL.
--
--   1. Enquanto a Esmeralda esta no prazo dela, o convidado que a
--      Esmeralda indicou NAO aparece para mais ninguem: esta reservado.
--   2. A vez passa para a Diamante quando a Esmeralda termina de
--      escolher (encerra, passa a vez ou enche a mesa) OU quando o
--      prazo da cota dela vence — o que vier primeiro.
--   3. Se a Esmeralda escolheu a pessoa, ela fica presa la: convidado
--      confirmado some da lista de todo mundo. Isso ja funcionava.
--   4. Se o prazo venceu sem ela escolher, a reserva cai e o convidado
--      volta para a lista geral.
--
-- O prazo NAO tira a empresa da disputa: vencido o prazo, ela perde a
-- prioridade e as reservas, mas continua podendo escolher entre quem
-- estiver livre. Perder o prazo custa a fila, nao a mesa.
--
-- ONDE FICA O PRAZO
--
-- Em `cotas.prazo_indicacao`, uma data por cota por evento — e assim
-- que a fila escalona: Esmeralda ate 01/09, Diamante ate 08/09, e por
-- ai. Cota sem prazo preenchido segura a vez ate encerrar ou passar,
-- que e exatamente o comportamento de antes desta migration.
--
-- POR QUE HA DROP
--
-- `admin_listar_cotas` ganha coluna no retorno e `admin_salvar_cota`
-- ganha parametro. Nenhuma das duas aceita `create or replace` com
-- assinatura nova: sem o drop, o Postgres criaria uma SOBRECARGA e as
-- chamadas antigas continuariam caindo na versao velha, sem erro
-- nenhum na tela.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. O PRAZO
-- ---------------------------------------------------------------------
alter table cotas add column if not exists prazo_indicacao date;

comment on column cotas.prazo_indicacao is
  'Ate quando esta cota escolhe. Vencido, a fila anda e as reservas de indicacao dela caem. Nulo = sem prazo.';

-- ---------------------------------------------------------------------
-- 2. QUEM AINDA SEGURA A VEZ
--
-- Uma sessao esta em aberto enquanto a empresa ainda pode escolher
-- nela. E a mesma condicao que responde as duas perguntas do modulo:
-- "quem esta na minha frente?" e "essa indicacao ainda vale?".
-- ---------------------------------------------------------------------
create or replace function _escolha_em_aberto(p_sessao_id uuid)
returns boolean language sql stable security definer
set search_path = gestao, public as $$
  select s.passou_em is null
     and s.escolha_encerrada_em is null
     and (select count(*) from sessao_convidados sc
           where sc.sessao_id = s.id and sc.status = 'confirmado') < s.vagas
     and (c.prazo_indicacao is null or current_date <= c.prazo_indicacao)
  from sessoes s
  join patrocinadores p on p.id = s.patrocinador_id
  join cotas c on c.id = p.cota_id
  where s.id = p_sessao_id;
$$;

-- Quem tem o convidado reservado agora — ou nulo, se ninguem tem.
--
-- Reserva so existe enquanto quem indicou tem sessao em aberto DAQUELE
-- tipo. Se a empresa nem tem mesa redonda, nao ha o que reservar numa
-- mesa redonda.
create or replace function _reserva_da_indicacao(p_participante_id uuid, p_tipo text)
returns uuid language sql stable security definer
set search_path = gestao, public as $$
  select pa.indicado_por_patrocinador_id
  from participantes pa
  where pa.id = p_participante_id
    and pa.indicado_por_patrocinador_id is not null
    and exists (
      select 1 from sessoes s
      where s.patrocinador_id = pa.indicado_por_patrocinador_id
        and s.evento_id = pa.evento_id
        and s.tipo = p_tipo
        and _escolha_em_aberto(s.id)
    );
$$;

-- ---------------------------------------------------------------------
-- 3. A FILA ANDA SOZINHA QUANDO O PRAZO VENCE
-- ---------------------------------------------------------------------
create or replace function patro_minha_vez(p_sessao_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_patro uuid; v_evento uuid; v_tipo text; v_vagas int;
  v_pos bigint; v_na_frente int; v_escolhidos int;
  v_prazo date;
begin
  select s.patrocinador_id, s.evento_id, s.tipo, s.vagas
    into v_patro, v_evento, v_tipo, v_vagas
  from sessoes s where s.id = p_sessao_id;

  perform _exige_patrocinador(v_patro);

  select o.posicao into v_pos
  from v_ordem_escolha o where o.patrocinador_id = v_patro;

  select c.prazo_indicacao into v_prazo
  from patrocinadores p join cotas c on c.id = p.cota_id
  where p.id = v_patro;

  -- Antes contava quem tinha vaga e nao tinha passado a vez. Agora e
  -- _escolha_em_aberto, que inclui o prazo: cota vencida deixa de
  -- segurar a fila.
  select count(*) into v_na_frente
  from sessoes s2
  join v_ordem_escolha o2 on o2.patrocinador_id = s2.patrocinador_id
  where s2.evento_id = v_evento
    and s2.tipo = v_tipo
    and o2.posicao < coalesce(v_pos, 999999)
    and _escolha_em_aberto(s2.id);

  select count(*) into v_escolhidos from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  return jsonb_build_object(
    'minha_vez',     v_na_frente = 0,
    'posicao',       coalesce(v_pos, 0),
    'na_frente',     v_na_frente,
    'vagas',         v_vagas,
    'escolhidos',    v_escolhidos,
    'prazo',         v_prazo,
    'prazo_vencido', v_prazo is not null and current_date > v_prazo
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. A LISTA ESCONDE QUEM ESTA RESERVADO PARA OUTRA EMPRESA
-- ---------------------------------------------------------------------
create or replace function patro_convidados_disponiveis(p_sessao_id uuid)
returns table (
  participante_id uuid,
  nome text,
  empresa text,
  cargo text,
  segmento text,
  indicado_por_mim boolean
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare s record;
begin
  select * into s from sessoes where id = p_sessao_id;
  if s.id is null then
    raise exception 'Sessao nao encontrada.' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(s.patrocinador_id);

  return query
  select
    pa.id, g.nome, g.empresa, g.cargo, g.segmento,
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false)
      as indicado_por_mim
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join participante_perfil pp on pp.participante_id = pa.id
  where pa.evento_id = s.evento_id
    and pa.status = 'aprovado'
    -- quem ja foi escolhido por qualquer empresa some da lista de todo
    -- mundo, dentro do mesmo tipo de sessao — e o que a tela promete
    and not exists (
      select 1 from sessao_convidados sc
      join sessoes s2 on s2.id = sc.sessao_id
      where sc.participante_id = pa.id
        and sc.status = 'confirmado'
        and s2.evento_id = s.evento_id
        and s2.tipo = s.tipo
    )
    -- e quem outra empresa indicou fica invisivel enquanto ela estiver
    -- no prazo. Vencido o prazo, a reserva cai e ele reaparece aqui.
    and coalesce(_reserva_da_indicacao(pa.id, s.tipo), s.patrocinador_id)
        = s.patrocinador_id
  order by
    -- o coalesce nao e decoracao: "null = uuid" da NULL, e em desc o
    -- Postgres ordena NULL, true, false — sem ele os NAO indicados
    -- subiriam acima dos indicados
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false) desc,
    _porte_faturamento(pp.faturamento) desc,
    g.nome;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. E A ESCOLHA RECUSA O QUE ESTA RESERVADO
--
-- A tela ja nao mostra, mas a tela e estatica e a lista de uuid chega
-- pela API: a regra tem que estar aqui tambem.
-- ---------------------------------------------------------------------
create or replace function patro_escolher_convidados(
  p_sessao_id uuid,
  p_participantes uuid[]
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_patro uuid; v_vagas int; v_tipo text; v_evento uuid;
  v_atual int; v_vez jsonb; v_inseridos int := 0; v_p uuid;
  v_dono uuid; v_empresa text;
begin
  select s.patrocinador_id, s.vagas, s.tipo, s.evento_id
    into v_patro, v_vagas, v_tipo, v_evento
  from sessoes s where s.id = p_sessao_id
  for update;                       -- trava a sessao durante a escolha

  perform _exige_patrocinador(v_patro);

  v_vez := patro_minha_vez(p_sessao_id);
  if not (v_vez ->> 'minha_vez')::boolean then
    raise exception 'Ainda nao e a sua vez de escolher (% na frente)',
      v_vez ->> 'na_frente' using errcode = '55000';
  end if;

  select count(*) into v_atual from sessao_convidados
   where sessao_id = p_sessao_id and status = 'confirmado';

  if v_atual + array_length(p_participantes,1) > v_vagas then
    raise exception 'Cota de % vaga(s); voce ja tem % e tentou somar %',
      v_vagas, v_atual, array_length(p_participantes,1)
      using errcode = '22023';
  end if;

  foreach v_p in array p_participantes loop
    -- ninguem pode estar em duas sessoes do mesmo tipo
    if exists (
      select 1 from sessao_convidados sc
      join sessoes s3 on s3.id = sc.sessao_id
      where sc.participante_id = v_p and sc.status = 'confirmado'
        and s3.evento_id = v_evento and s3.tipo = v_tipo
    ) then
      raise exception 'Convidado ja esta em outra sessao deste tipo'
        using errcode = '23505';
    end if;

    v_dono := _reserva_da_indicacao(v_p, v_tipo);
    if v_dono is not null and v_dono <> v_patro then
      select empresa into v_empresa from patrocinadores where id = v_dono;
      raise exception 'Convidado indicado pela %, que ainda esta no prazo', v_empresa
        using errcode = '55000';
    end if;

    insert into sessao_convidados (sessao_id, participante_id, origem)
    values (p_sessao_id, v_p, 'patrocinador');
    v_inseridos := v_inseridos + 1;
  end loop;

  if v_atual + v_inseridos >= v_vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'inseridos', v_inseridos,
                            'total', v_atual + v_inseridos, 'vagas', v_vagas);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. O PRAZO NA TELA DA ORGANIZACAO
-- ---------------------------------------------------------------------
drop function if exists admin_listar_cotas(text);

create function admin_listar_cotas(p_evento_slug text)
returns table (id uuid, nome text, ordem_prioridade int,
               quartos jsonb, total_quartos bigint,
               vagas_mesa_redonda int, tem_reuniao_exclusiva boolean,
               tem_jantar boolean, patrocinadores bigint,
               lista_patrocinadores jsonb, prazo_indicacao date)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select c.id, c.nome, c.ordem_prioridade,
           coalesce((select jsonb_object_agg(cq.tipo, cq.quantidade)
                     from cota_quartos cq where cq.cota_id = c.id
                       and cq.quantidade > 0), '{}'::jsonb),
           coalesce((select sum(cq.quantidade) from cota_quartos cq
                     where cq.cota_id = c.id), 0),
           c.vagas_mesa_redonda, c.tem_reuniao_exclusiva, c.tem_jantar,
           (select count(*) from patrocinadores p where p.cota_id = c.id),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', p.id, 'empresa', p.empresa) order by p.empresa)
                     from patrocinadores p
                     where p.cota_id = c.id and p.status = 'ativo'), '[]'::jsonb),
           c.prazo_indicacao
    from cotas c
    join eventos e on e.id = c.evento_id and e.slug = p_evento_slug
    order by c.ordem_prioridade;
end;
$$;

-- p_quartos vem como {"duplo":2,"single":2}
drop function if exists admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean);

create function admin_salvar_cota(
  p_evento_slug text,
  p_nome text,
  p_ordem int,
  p_quartos jsonb default '{}'::jsonb,
  p_vagas_mesa int default 0,
  p_reuniao boolean default false,
  p_jantar boolean default false,
  p_prazo_indicacao date default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_unica boolean; v_conflito text;
  v_cota uuid; v_par record; v_ordem int; v_total int := 0;
begin
  perform _exige_admin();

  select id, cota_unica into v_evento, v_unica
  from eventos where slug = p_evento_slug;

  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if coalesce(trim(p_nome),'') = '' then
    raise exception 'Informe o nome da cota' using errcode='22023';
  end if;

  -- Em evento de cota unica nao ha fila, entao a ordem nao e pedida na
  -- tela; forcamos 1 para nao deixar nulo e quebrar a view de ordem.
  v_ordem := case when v_unica then 1 else p_ordem end;

  if v_ordem is null or v_ordem < 1 then
    raise exception 'A ordem de prioridade comeca em 1' using errcode='22023';
  end if;

  if not v_unica then
    select c.nome into v_conflito from cotas c
     where c.evento_id = v_evento and c.ordem_prioridade = v_ordem
       and lower(c.nome) <> lower(trim(p_nome));
    if v_conflito is not null then
      raise exception 'A posicao % ja e da cota "%"', v_ordem, v_conflito
        using errcode='23505';
    end if;
  end if;

  insert into cotas (evento_id, nome, ordem_prioridade, vagas_mesa_redonda,
                     tem_reuniao_exclusiva, tem_jantar,
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao
  returning id into v_cota;

  -- composicao substitui a anterior inteira: a tela edita o conjunto
  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  -- mantem as colunas antigas coerentes para quem ainda as le
  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. PERMISSAO
--
-- As duas recriadas nascem sem o ACL antigo; os helpers sao novos.
-- ---------------------------------------------------------------------
revoke execute on function admin_listar_cotas(text) from public, anon;
revoke execute on function admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean, date) from public, anon;
revoke execute on function _escolha_em_aberto(uuid) from public, anon;
revoke execute on function _reserva_da_indicacao(uuid, text) from public, anon;
grant execute on function admin_listar_cotas(text) to authenticated, service_role;
grant execute on function admin_salvar_cota(text, text, int, jsonb, int, boolean, boolean, date) to authenticated, service_role;
grant execute on function _escolha_em_aberto(uuid) to authenticated, service_role;
grant execute on function _reserva_da_indicacao(uuid, text) to authenticated, service_role;
