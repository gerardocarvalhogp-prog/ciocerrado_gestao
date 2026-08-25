-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-financeiro.sql  ·  valores extras, cobranca e relatorio
--
-- Rodar DEPOIS de funcoes-etiquetas.sql.
--
-- Fecha um buraco: quarto extra comprado pelo patrocinador nunca virava
-- fatura. So o participante tinha calculo, e mesmo assim so quando ele
-- mesmo abria a tela.
-- =====================================================================

set search_path = gestao, public;

-- Data de vencimento e observacao, para a cobranca ter o que mostrar.
alter table faturas add column if not exists vencimento date;
alter table faturas add column if not exists observacao text;
alter table faturas add column if not exists forma_pagamento text;

-- =====================================================================
-- 1. RECALCULO
-- =====================================================================

-- Versao administrativa do calculo do participante. A part_calcular_fatura
-- so funciona para o proprio usuario logado; esta roda para qualquer um.
create or replace function _recalcular_fatura_participante(p_participante_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_res uuid; v_fatura uuid;
  v_adultos int; v_criancas int; v_transfers int;
  v_pa numeric(12,2); v_pc numeric(12,2); v_pt numeric(12,2);
  v_total numeric(12,2) := 0;
begin
  select evento_id into v_evento from participantes where id = p_participante_id;
  if v_evento is null then return 0; end if;

  select id into v_res from reservas
   where participante_id = p_participante_id and status <> 'cancelado';
  if v_res is null then return 0; end if;

  select coalesce((select valor from precos where evento_id=v_evento and item='acompanhante_adulto'),0),
         coalesce((select valor from precos where evento_id=v_evento and item='crianca'),0),
         coalesce((select valor from precos where evento_id=v_evento and item='transfer'),0)
    into v_pa, v_pc, v_pt;

  select count(*) filter (where tipo='adulto'),
         count(*) filter (where tipo='crianca'),
         count(*) filter (where usa_transfer)
    into v_adultos, v_criancas, v_transfers
  from ocupantes where reserva_id = v_res;

  -- so mexe na estimada: emitida ou paga e documento, nao rascunho
  select id into v_fatura from faturas
   where participante_id = p_participante_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, participante_id, status)
    values (v_evento, p_participante_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  if v_adultos > 0 then
    insert into fatura_itens (fatura_id, reserva_id, descricao, quantidade, valor_unit)
    values (v_fatura, v_res, 'Acompanhante adulto', v_adultos, v_pa);
    v_total := v_total + v_adultos * v_pa;
  end if;
  if v_criancas > 0 then
    insert into fatura_itens (fatura_id, reserva_id, descricao, quantidade, valor_unit)
    values (v_fatura, v_res, 'Criança', v_criancas, v_pc);
    v_total := v_total + v_criancas * v_pc;
  end if;
  if v_transfers > 0 then
    insert into fatura_itens (fatura_id, reserva_id, descricao, quantidade, valor_unit)
    values (v_fatura, v_res, 'Transfer', v_transfers, v_pt);
    v_total := v_total + v_transfers * v_pt;
  end if;

  update faturas set total = v_total where id = v_fatura;
  return v_total;
end;
$$;

-- Patrocinador: quarto extra (o que passou da cota) e transfer da equipe.
create or replace function _recalcular_fatura_patrocinador(p_patrocinador_id uuid)
returns numeric language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_fatura uuid; v_total numeric(12,2) := 0;
  v_linha record; v_pt numeric(12,2); v_transfers int;
begin
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then return 0; end if;

  select id into v_fatura from faturas
   where patrocinador_id = p_patrocinador_id and status = 'estimada';

  if v_fatura is null then
    insert into faturas (evento_id, patrocinador_id, status)
    values (v_evento, p_patrocinador_id, 'estimada')
    returning id into v_fatura;
  else
    delete from fatura_itens where fatura_id = v_fatura;
  end if;

  -- um item por tipo de quarto extra, com o preco daquele tipo
  for v_linha in
    select r.tipo, count(*) as qtd,
           coalesce((select valor from precos
                     where evento_id = v_evento
                       and item = 'quarto_' || r.tipo), 0) as valor
    from reservas r
    where r.patrocinador_id = p_patrocinador_id
      and r.origem = 'extra' and r.status <> 'cancelado'
    group by r.tipo
  loop
    insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
    values (v_fatura, 'Quarto extra ' || v_linha.tipo, v_linha.qtd, v_linha.valor);
    v_total := v_total + v_linha.qtd * v_linha.valor;
  end loop;

  select coalesce((select valor from precos
                   where evento_id=v_evento and item='transfer'),0) into v_pt;

  select count(*) into v_transfers
  from ocupantes o
  join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
  where r.patrocinador_id = p_patrocinador_id and o.usa_transfer;

  if v_transfers > 0 and v_pt > 0 then
    insert into fatura_itens (fatura_id, descricao, quantidade, valor_unit)
    values (v_fatura, 'Transfer', v_transfers, v_pt);
    v_total := v_total + v_transfers * v_pt;
  end if;

  update faturas set total = v_total where id = v_fatura;

  -- fatura zerada e ruido na lista de cobranca
  if v_total = 0 then
    delete from fatura_itens where fatura_id = v_fatura;
    delete from faturas where id = v_fatura;
  end if;

  return v_total;
end;
$$;

create or replace function admin_recalcular_faturas(p_evento_slug text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_r record; v_np int := 0; v_ns int := 0;
  v_total numeric(12,2) := 0; v_v numeric(12,2);
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;

  for v_r in
    select pa.id from participantes pa
    where pa.evento_id = v_evento and pa.status = 'aprovado'
  loop
    v_v := _recalcular_fatura_participante(v_r.id);
    if v_v > 0 then v_np := v_np + 1; v_total := v_total + v_v; end if;
  end loop;

  for v_r in
    select p.id from patrocinadores p
    where p.evento_id = v_evento and p.status = 'ativo'
  loop
    v_v := _recalcular_fatura_patrocinador(v_r.id);
    if v_v > 0 then v_ns := v_ns + 1; v_total := v_total + v_v; end if;
  end loop;

  return jsonb_build_object('ok', true, 'participantes', v_np,
                            'patrocinadores', v_ns, 'total', v_total);
end;
$$;

-- =====================================================================
-- 2. LISTAGEM
-- =====================================================================

create or replace function admin_listar_faturas(
  p_evento_slug text,
  p_status text default null,
  p_limite int default 500,
  p_offset int default 0
) returns table (
  id uuid, tipo text, nome text, empresa text, email text,
  total numeric, status text, vencimento date,
  emitida_em timestamptz, paga_em timestamptz,
  forma_pagamento text, observacao text,
  itens text, total_geral bigint
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select f.id,
           case when f.participante_id is not null then 'participante'
                else 'patrocinador' end,
           coalesce(g.nome, p.empresa),
           coalesce(g.empresa, p.empresa),
           coalesce(g.email, (select u.email from usuarios_patrocinador u
                              where u.patrocinador_id = p.id and u.ativo
                              order by u.created_at limit 1)),
           f.total, f.status, f.vencimento,
           f.emitida_em, f.paga_em, f.forma_pagamento, f.observacao,
           -- resumo dos itens em uma linha: evita segunda consulta so
           -- para mostrar "1 acompanhante + transfer"
           coalesce((select string_agg(fi.descricao || ' ×' || fi.quantidade, ', '
                                       order by fi.descricao)
                     from fatura_itens fi where fi.fatura_id = f.id), '—'),
           count(*) over ()
    from faturas f
    join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
    left join participantes pa on pa.id = f.participante_id
    left join gestores g on g.id = pa.gestor_id
    left join patrocinadores p on p.id = f.patrocinador_id
    where f.status <> 'cancelada'
      and (p_status is null or f.status = p_status)
    order by (f.status = 'paga'), f.total desc
    limit p_limite offset p_offset;
end;
$$;

create or replace function admin_fatura_itens(p_fatura_id uuid)
returns table (descricao text, quantidade int,
               valor_unit numeric, valor_total numeric)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select fi.descricao, fi.quantidade, fi.valor_unit, fi.valor_total
    from fatura_itens fi where fi.fatura_id = p_fatura_id
    order by fi.descricao;
end;
$$;

-- =====================================================================
-- 3. MARCAR PAGO / EM ABERTO
-- =====================================================================

create or replace function admin_marcar_fatura(
  p_fatura_id uuid,
  p_status text,
  p_forma_pagamento text default null,
  p_observacao text default null,
  p_vencimento date default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_ant text;
begin
  perform _exige_admin();

  select status into v_ant from faturas where id = p_fatura_id;
  if v_ant is null then
    raise exception 'Fatura nao encontrada' using errcode='P0002';
  end if;
  if p_status not in ('estimada','emitida','paga','cancelada') then
    raise exception 'Status invalido: %', p_status using errcode='22023';
  end if;

  update faturas set
    status = p_status,
    -- carimba a data na primeira vez que entra no estado, e limpa se
    -- voltar atras: fatura reaberta com data de pagamento antiga
    -- confunde a conferencia
    emitida_em = case
      when p_status in ('emitida','paga') then coalesce(emitida_em, now())
      else null end,
    paga_em = case
      when p_status = 'paga' then coalesce(paga_em, now())
      else null end,
    forma_pagamento = case
      when p_status = 'paga' then coalesce(p_forma_pagamento, forma_pagamento)
      else forma_pagamento end,
    observacao = coalesce(p_observacao, observacao),
    vencimento = coalesce(p_vencimento, vencimento)
  where id = p_fatura_id;

  return jsonb_build_object('ok', true, 'de', v_ant, 'para', p_status);
end;
$$;

-- =====================================================================
-- 4. RESUMO
-- =====================================================================

create or replace function admin_financeiro_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare
  v_aberto numeric(12,2); v_pago numeric(12,2);
  v_n_aberto int; v_n_pago int; v_vencido int;
begin
  perform _exige_staff();

  select coalesce(sum(f.total) filter (where f.status <> 'paga'),0),
         coalesce(sum(f.total) filter (where f.status = 'paga'),0),
         count(*) filter (where f.status <> 'paga'),
         count(*) filter (where f.status = 'paga'),
         count(*) filter (where f.status <> 'paga'
                            and f.vencimento is not null
                            and f.vencimento < current_date)
    into v_aberto, v_pago, v_n_aberto, v_n_pago, v_vencido
  from faturas f
  join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
  where f.status <> 'cancelada';

  return jsonb_build_object(
    'em_aberto', v_aberto, 'recebido', v_pago,
    'total', v_aberto + v_pago,
    'qtd_aberto', v_n_aberto, 'qtd_pago', v_n_pago,
    'vencidas', v_vencido);
end;
$$;

grant execute on function
  admin_recalcular_faturas(text),
  admin_listar_faturas(text, text, int, int),
  admin_fatura_itens(uuid),
  admin_marcar_fatura(uuid, text, text, text, date),
  admin_financeiro_resumo(text)
to authenticated;
