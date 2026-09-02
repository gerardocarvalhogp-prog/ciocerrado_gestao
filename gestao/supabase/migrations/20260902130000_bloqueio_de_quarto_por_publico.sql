-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloqueio/vinculação de quartos por público (CIO / Organização /
-- Cotas), antes mesmo de vendas/inscrições, com liberação depois.
--
-- O RISCO QUE NAO EXISTIA PROTEGIDO
--
-- O inventario de quartos (tabela `quartos`) sempre foi um pool unico:
-- nenhum numero era reservado de antemao pra nenhum publico. Isso nao
-- dava problema em admin_alocar_quarto (o staff escolhe na mao, um a
-- um, ve o que esta livre). Mas dava em part_comprar_quarto e
-- patro_comprar_quarto — os dois reivindicam um quarto disponivel na
-- hora, sem supervisao, do MESMO pool. Se muitos CIOs comprassem
-- quarto extra antes da organizacao terminar de fechar cota com um
-- patrocinador grande, o quarto que faltava pra cota nao existia mais.
--
-- publico_alvo em `quartos` deixa reservar um numero pra um publico
-- especifico ANTES de qualquer venda. NULL (o padrao) continua sendo
-- pool geral — nada muda pra quem nunca usar isso.
-- =====================================================================

set search_path = gestao, public;

alter table quartos add column if not exists publico_alvo text;
alter table quartos drop constraint if exists quartos_publico_alvo_check;
alter table quartos add constraint quartos_publico_alvo_check
  check (publico_alvo is null or publico_alvo in ('cio','organizacao','cotas'));
comment on column quartos.publico_alvo is
  'NULL = pool geral (comportamento de sempre). Preenchido = reservado pra esse publico antes mesmo de vendas/inscricoes; libera voltando pra NULL.';

-- ---------------------------------------------------------------------
-- 1. BLOQUEAR/LIBERAR — um quarto ou uma faixa inteira
-- ---------------------------------------------------------------------
drop function if exists admin_editar_tipo_quarto(uuid, text);

create or replace function admin_editar_tipo_quarto(p_id uuid, p_tipo text, p_publico_alvo text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_numero text;
begin
  perform _exige_admin();

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido: %. Use single, duplo ou triplo', p_tipo
      using errcode = '22023';
  end if;
  if p_publico_alvo is not null and p_publico_alvo not in ('cio','organizacao','cotas') then
    raise exception 'Publico invalido: %', p_publico_alvo using errcode = '22023';
  end if;

  update quartos set
    tipo = p_tipo,
    capacidade = case p_tipo when 'single' then 1 when 'duplo' then 2 else 3 end,
    publico_alvo = p_publico_alvo
  where id = p_id
  returning numero into v_numero;

  if not found then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'numero', v_numero, 'tipo', p_tipo, 'publico_alvo', p_publico_alvo);
end;
$$;

create or replace function admin_definir_publico_faixa(p_evento_slug text, p_de text, p_ate text, p_publico_alvo text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_n int; v_de int; v_ate int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;
  if p_publico_alvo is not null and p_publico_alvo not in ('cio','organizacao','cotas') then
    raise exception 'Publico invalido: %', p_publico_alvo using errcode = '22023';
  end if;

  v_de  := nullif(regexp_replace(coalesce(p_de,''),  '[^0-9]', '', 'g'), '')::int;
  v_ate := nullif(regexp_replace(coalesce(p_ate,''), '[^0-9]', '', 'g'), '')::int;

  if v_de is null or v_ate is null or v_ate < v_de then
    raise exception 'Faixa invalida: de % ate %', p_de, p_ate using errcode = '22023';
  end if;

  update quartos q set publico_alvo = p_publico_alvo
  where q.evento_id = v_evento
    and q.numero ~ '^[0-9]+$'
    and q.numero::int between v_de and v_ate
    and q.publico_alvo is distinct from p_publico_alvo;

  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'alterados', v_n, 'de', v_de, 'ate', v_ate, 'publico_alvo', p_publico_alvo);
end;
$$;

revoke execute on function admin_editar_tipo_quarto(uuid,text,text) from public, anon;
revoke execute on function admin_definir_publico_faixa(text,text,text,text) from public, anon;
grant execute on function admin_editar_tipo_quarto(uuid,text,text) to authenticated, service_role;
grant execute on function admin_definir_publico_faixa(text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. QUEM VE O QUARTO PRECISA SABER DE QUEM ELE E
-- ---------------------------------------------------------------------
drop function if exists admin_listar_quartos_individual(text, text);

create or replace function admin_listar_quartos_individual(p_evento_slug text, p_busca text DEFAULT NULL::text)
returns table(id uuid, numero text, tipo text, capacidade integer, status text, bloco text,
              andar text, corredor text, categoria text, publico_alvo text,
              reserva_id uuid, ocupado_por text)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_termo text;
begin
  perform _exige_staff();
  v_termo := nullif(trim(coalesce(p_busca,'')), '');

  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.status,
           q.bloco, q.andar, q.corredor, q.categoria, q.publico_alvo,
           r.id,
           coalesce(p.empresa, g.empresa, r.rotulo)
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    left join reservas r on r.quarto_id = q.id and r.status <> 'cancelado'
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where v_termo is null
       or q.numero ilike '%'||v_termo||'%'
       or coalesce(q.bloco,'') ilike '%'||v_termo||'%'
    order by
      nullif(regexp_replace(coalesce(q.numero,''),'[^0-9]','','g'),'')::int nulls last,
      q.numero;
end;
$$;

revoke execute on function admin_listar_quartos_individual(text,text) from public, anon;
grant execute on function admin_listar_quartos_individual(text,text) to authenticated, service_role;

-- admin_quartos_livres alimenta o seletor de "Separar quartos" — cada
-- linha da tela filtra pelo publico da propria reserva (calculado em
-- admin_listar_alocacao, abaixo), entao aqui so precisa devolver o
-- publico_alvo de cada quarto livre pra tela decidir
drop function if exists admin_quartos_livres(text);

create or replace function admin_quartos_livres(p_evento_slug text)
returns table(id uuid, numero text, tipo text, capacidade integer, publico_alvo text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.publico_alvo
    from quartos q
    join eventos e on e.id = q.evento_id and e.slug = p_evento_slug
    where q.status <> 'bloqueado'
      and not exists (select 1 from reservas r
                      where r.quarto_id = q.id and r.status <> 'cancelado')
    order by q.numero nulls last;
end;
$$;

revoke execute on function admin_quartos_livres(text) from public, anon;
grant execute on function admin_quartos_livres(text) to authenticated, service_role;

-- admin_listar_alocacao ganha o publico da reserva (equipe->organizacao,
-- cota ou patrocinador_id preenchido->cotas, resto->cio), pra tela so
-- oferecer no seletor os quartos compativeis
drop function if exists admin_listar_alocacao(text, boolean);

create or replace function admin_listar_alocacao(p_evento_slug text, p_apenas_sem_quarto boolean DEFAULT false)
returns table(ocupante_id uuid, reserva_id uuid, nome text, empresa text, tipo text,
              quarto_id uuid, quarto_numero text, quarto_tipo text, publico text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select o.id, r.id, o.nome,
           coalesce(p.empresa, g.empresa, r.rotulo),
           o.tipo, q.id, q.numero, r.tipo,
           case
             when r.origem = 'equipe' then 'organizacao'
             when r.origem = 'cota' or r.patrocinador_id is not null then 'cotas'
             else 'cio'
           end
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    join eventos  e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where (not p_apenas_sem_quarto or r.quarto_id is null)
    order by coalesce(p.empresa, g.empresa, r.rotulo), o.nome;
end;
$$;

revoke execute on function admin_listar_alocacao(text,boolean) from public, anon;
grant execute on function admin_listar_alocacao(text,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3. O BLOQUEIO DE VERDADE: quem tenta pegar quarto errado e recusado
-- ---------------------------------------------------------------------
create or replace function admin_alocar_quarto(p_reserva_id uuid, p_quarto_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_anterior uuid; v_ocupado uuid; v_cap int; v_tipo text; v_qtd int;
  v_publico_quarto text; v_publico_reserva text;
begin
  perform _exige_staff_da_reserva(p_reserva_id);

  select quarto_id into v_anterior from reservas where id = p_reserva_id;
  if not found then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;

  if p_quarto_id is null then
    update reservas set quarto_id = null where id = p_reserva_id;
    update quartos set status = 'disponivel' where id = v_anterior;
    return jsonb_build_object('ok', true, 'liberado', true);
  end if;

  select q.capacidade, q.tipo, q.publico_alvo into v_cap, v_tipo, v_publico_quarto
  from quartos q where q.id = p_quarto_id for update;

  if v_publico_quarto is not null then
    select case
             when r.origem = 'equipe' then 'organizacao'
             when r.origem = 'cota' or r.patrocinador_id is not null then 'cotas'
             else 'cio'
           end
      into v_publico_reserva
    from reservas r where r.id = p_reserva_id;

    if v_publico_reserva <> v_publico_quarto then
      return jsonb_build_object('ok', false, 'motivo', 'publico_incompativel',
                                'publico_quarto', v_publico_quarto, 'publico_reserva', v_publico_reserva);
    end if;
  end if;

  select r.id into v_ocupado from reservas r
   where r.quarto_id = p_quarto_id and r.status <> 'cancelado'
     and r.id <> p_reserva_id
   limit 1;

  if v_ocupado is not null then
    return jsonb_build_object('ok', false, 'motivo', 'quarto_ocupado');
  end if;

  select count(*) into v_qtd from ocupantes where reserva_id = p_reserva_id;

  if v_qtd > v_cap then
    return jsonb_build_object('ok', false, 'motivo', 'capacidade',
      'ocupantes', v_qtd, 'capacidade', v_cap);
  end if;

  update reservas set quarto_id = p_quarto_id where id = p_reserva_id;
  update quartos set status = 'reservado' where id = p_quarto_id;

  if v_anterior is not null and v_anterior <> p_quarto_id then
    update quartos set status = 'disponivel' where id = v_anterior;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. AS COMPRAS AUTOMATICAS (sem supervisao) SO PEGAM DO PROPRIO POOL
-- ---------------------------------------------------------------------
create or replace function part_comprar_quarto(p_evento_slug text, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_part    uuid;
  v_evento  uuid;
  v_quarto  uuid;
  v_reserva uuid;
  v_seq     int;
begin
  v_part := _meu_participante(p_evento_slug);
  if v_part is null then
    raise exception 'Inscricao nao encontrada' using errcode = 'P0002';
  end if;

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from participantes where id = v_part;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and (q.publico_alvo is null or q.publico_alvo = 'cio')
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last
  limit 1
  for update of q skip locked;

  if v_quarto is null then
    return jsonb_build_object('ok', false, 'motivo', 'sem_disponibilidade');
  end if;

  update quartos set status = 'reservado' where id = v_quarto;

  select count(*) + 1 into v_seq from reservas
   where participante_id = v_part and origem = 'extra' and status <> 'cancelado';

  insert into reservas (evento_id, quarto_id, participante_id, rotulo,
                        tipo, origem, status)
  values (v_evento, v_quarto, v_part,
          'Quarto extra ' || v_seq, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  perform _recalcular_fatura_participante(v_part);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva);
end;
$$;

create or replace function patro_comprar_quarto(p_patrocinador_id uuid, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento  uuid;
  v_quarto  uuid;
  v_reserva uuid;
  v_seq     int;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and (q.publico_alvo is null or q.publico_alvo = 'cotas')
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last
  limit 1
  for update of q skip locked;

  if v_quarto is null then
    return jsonb_build_object('ok', false, 'motivo', 'sem_disponibilidade');
  end if;

  update quartos set status = 'reservado' where id = v_quarto;

  select count(*) + 1 into v_seq from reservas
   where patrocinador_id = p_patrocinador_id and status <> 'cancelado';

  insert into reservas (evento_id, quarto_id, patrocinador_id, rotulo,
                        tipo, origem, status)
  values (v_evento, v_quarto, p_patrocinador_id,
          'Quarto ' || v_seq, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', 'Quarto ' || v_seq);
end;
$$;
