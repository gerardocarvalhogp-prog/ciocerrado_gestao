-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Bloco 1 — ajustes diretos em Quartos e Rooming.
--
-- 1.1 Remove o mecanismo de "Publico" (publico_alvo) por inteiro —
--     decisao explicita do organizador, ciente do risco que a
--     migration de 02/09 tinha fechado (CIO e patrocinador podiam
--     disputar o mesmo numero de quarto). Como o item 1.6 tira a
--     compra de quarto extra do CIO, o unico caminho automatico que
--     sobra e' patro_comprar_quarto — que volta a pescar do pool
--     geral, igual a antes de 02/09.
--
-- 1.2 "Ocupado por" vira campo de texto livre por reserva
--     (reservas.ocupado_por), digitado pelo staff — nome da pessoa e
--     empresa, sem depender do patrocinador do contrato. Continua
--     caindo pro valor derivado (empresa do contrato / gestor / rotulo)
--     enquanto ninguem tiver digitado nada.
--
-- 1.5 Unifica os campos do quarto do patrocinador (portal.html) com os
--     do rooming do CIO (rooming.html): tipo (adulto/crianca), data de
--     nascimento, dificuldade de mobilidade, alergia (+ detalhe),
--     berco, observacoes. As colunas ja existiam em `ocupantes` desde
--     02/09 (checks_de_saude_no_rooming) — so o lado do patrocinador
--     nunca tinha sido atualizado pra ler/gravar.
--
-- 1.6 Remove a compra de quarto extra da area do CIO: part_comprar_quarto,
--     part_cancelar_quarto_extra e part_listar_meus_quartos so
--     serviam essa tela (confirmado — nenhum outro caller). O lado do
--     patrocinador (patro_comprar_quarto) continua existindo.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1.1a — reverte as funcoes que checavam publico_alvo
-- ---------------------------------------------------------------------
drop function if exists admin_editar_tipo_quarto(uuid, text, text);

create or replace function admin_editar_tipo_quarto(p_id uuid, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_numero text;
begin
  perform _exige_admin();

  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido: %. Use single, duplo ou triplo', p_tipo
      using errcode = '22023';
  end if;

  update quartos set
    tipo = p_tipo,
    capacidade = case p_tipo when 'single' then 1 when 'duplo' then 2 else 3 end
  where id = p_id
  returning numero into v_numero;

  if not found then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'numero', v_numero, 'tipo', p_tipo);
end;
$$;

revoke execute on function admin_editar_tipo_quarto(uuid, text) from public, anon;
grant execute on function admin_editar_tipo_quarto(uuid, text) to authenticated, service_role;

drop function if exists admin_definir_publico_faixa(text, text, text, text);

create or replace function admin_alocar_quarto(p_reserva_id uuid, p_quarto_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_anterior uuid; v_ocupado uuid; v_cap int; v_qtd int;
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

  select q.capacidade into v_cap from quartos q where q.id = p_quarto_id for update;

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
-- 1.2 — reservas ganha o campo de texto livre
-- ---------------------------------------------------------------------
alter table reservas add column if not exists ocupado_por text;
comment on column reservas.ocupado_por is
  'Nome + empresa digitados pelo staff, livre — nao precisa ser o patrocinador do contrato (pode ser outra empresa dividindo a cota). Enquanto vazio, a tela deriva do contrato/gestor/rotulo.';

create or replace function admin_definir_ocupado_por(p_reserva_id uuid, p_texto text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_da_reserva(p_reserva_id);

  update reservas set ocupado_por = nullif(trim(p_texto), '')
  where id = p_reserva_id;

  if not found then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function admin_definir_ocupado_por(uuid, text) from public, anon;
grant execute on function admin_definir_ocupado_por(uuid, text) to authenticated, service_role;

-- listagens que mostram "quem ocupa" passam a priorizar o texto livre
drop function if exists admin_listar_quartos_individual(text, text);

create function admin_listar_quartos_individual(p_evento_slug text, p_busca text DEFAULT NULL::text)
returns table (
  id uuid, numero text, tipo text, capacidade integer, status text,
  bloco text, andar text, corredor text, categoria text,
  reserva_id uuid, ocupado_por text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_termo text;
begin
  perform _exige_staff();
  v_termo := nullif(trim(coalesce(p_busca,'')), '');

  return query
    select q.id, q.numero, q.tipo, q.capacidade, q.status,
           q.bloco, q.andar, q.corredor, q.categoria,
           r.id,
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo)
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

revoke execute on function admin_listar_quartos_individual(text, text) from public, anon;
grant execute on function admin_listar_quartos_individual(text, text) to authenticated, service_role;

drop function if exists admin_quartos_livres(text);

create function admin_quartos_livres(p_evento_slug text)
returns table(id uuid, numero text, tipo text, capacidade integer)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select q.id, q.numero, q.tipo, q.capacidade
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

drop function if exists admin_listar_alocacao(text, boolean);

create function admin_listar_alocacao(p_evento_slug text, p_apenas_sem_quarto boolean DEFAULT false)
returns table(ocupante_id uuid, reserva_id uuid, nome text, empresa text, tipo text,
              quarto_id uuid, quarto_numero text, quarto_tipo text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select o.id, r.id, o.nome,
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo),
           o.tipo, q.id, q.numero, r.tipo
    from ocupantes o
    join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
    join eventos  e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    left join patrocinadores p on p.id = r.patrocinador_id
    left join participantes pa on pa.id = r.participante_id
    left join gestores g on g.id = pa.gestor_id
    where (not p_apenas_sem_quarto or r.quarto_id is null)
    order by coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo), o.nome;
end;
$$;

revoke execute on function admin_listar_alocacao(text,boolean) from public, anon;
grant execute on function admin_listar_alocacao(text,boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 1.1b — o pool volta a ser geral: sem filtro de publico_alvo
-- ---------------------------------------------------------------------
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

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', 'Quarto ' || v_seq);
end;
$$;

alter table quartos drop constraint if exists quartos_publico_alvo_check;
alter table quartos drop column if exists publico_alvo;

-- ---------------------------------------------------------------------
-- 1.6 — remove a compra de quarto extra do lado do CIO por inteiro
-- ---------------------------------------------------------------------
drop function if exists part_comprar_quarto(text, text);
drop function if exists part_cancelar_quarto_extra(uuid);
drop function if exists part_listar_meus_quartos(text);

-- ---------------------------------------------------------------------
-- 1.5 — unifica os campos do quarto do patrocinador com o rooming do CIO
-- ---------------------------------------------------------------------
drop function if exists patro_listar_ocupantes(uuid);

create function patro_listar_ocupantes(p_reserva_id uuid)
returns table (
  ocupante_id uuid, nome text, cpf text, data_nascimento date, tipo text,
  usa_transfer boolean, transfer_origem text,
  dificuldade_mobilidade boolean, tem_alergia boolean, alergia_detalhe text,
  precisa_berco boolean, observacoes text,
  email text, telefone text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_patro uuid;
begin
  select patrocinador_id into v_patro from reservas where id = p_reserva_id;
  perform _exige_patrocinador(v_patro);

  return query
    select o.id, o.nome, o.cpf, o.data_nascimento, o.tipo,
           o.usa_transfer, o.transfer_origem,
           o.dificuldade_mobilidade, o.tem_alergia, o.alergia_detalhe,
           o.precisa_berco, o.observacoes,
           o.email, o.telefone
    from ocupantes o
    where o.reserva_id = p_reserva_id
    order by o.created_at;
end;
$$;

revoke execute on function patro_listar_ocupantes(uuid) from public, anon;
grant execute on function patro_listar_ocupantes(uuid) to authenticated, service_role;

-- ATENCAO: a assinatura vigente e' a de 4 parametros
-- (20260826110000_brinde_da_empresa.sql) — o brinde saiu daqui faz
-- tempo, virou "um por empresa", nao mais por quarto. patro_salvar_quarto(uuid,jsonb,boolean,text,boolean,text)
-- com 6 parametros NUNCA foi a versao live; so existiu na baseline de
-- 24/08 e foi substituida no mesmo dia 26/08. DROP tem que mirar a
-- assinatura de 4, senao "create function" cria uma SEGUNDA funcao ao
-- lado da de 4 e o PostgREST passa a recusar toda chamada por
-- ambiguidade — foi exatamente o que aconteceu na primeira tentativa
-- desta migration, pego na validacao local antes de ir pro banco real.
drop function if exists patro_salvar_quarto(uuid, jsonb, boolean, text);

create function patro_salvar_quarto(
  p_reserva_id uuid, p_ocupantes jsonb,
  p_usa_transfer boolean DEFAULT NULL::boolean,
  p_transfer_origem text DEFAULT NULL::text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_patro uuid;
  v_tipo  text;
  v_cap   int;
  v_qtd   int;
  v_item  jsonb;
  v_limite date;
  v_nasc  date;
begin
  select patrocinador_id, tipo into v_patro, v_tipo
  from reservas where id = p_reserva_id and status <> 'cancelado';

  if v_patro is null then
    raise exception 'Reserva nao encontrada' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(v_patro);

  -- capacidade e' o mesmo teto flat de 4 usado em part_salvar_rooming
  -- desde 26/08 (cortesia_e_capacidade) — nao varia por tipo de quarto
  v_cap := _capacidade_quarto(v_tipo);
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));

  if v_qtd > v_cap then
    raise exception 'O quarto comporta % pessoa(s); voce enviou %. Acima disso e quarto adicional.',
      v_cap, v_qtd using errcode = '22023';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);

  select coalesce(e.data_inicio, current_date) into v_limite
  from reservas r join eventos e on e.id = r.evento_id
  where r.id = p_reserva_id;

  -- mesma validacao do rooming do CIO: nome obrigatorio, origem de
  -- transfer valida, data de nascimento obrigatoria pra crianca e
  -- nunca depois do evento comecar
  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'), '') = '' then
      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
    v_nasc := nullif(v_item ->> 'data_nascimento','')::date;
    if v_nasc is not null and v_nasc > v_limite then
      raise exception 'Data de nascimento depois do inicio do evento (%): %', v_limite, v_nasc
        using errcode = '22023';
    end if;
    if coalesce(v_item ->> 'tipo','adulto') = 'crianca' and v_nasc is null then
      raise exception 'Informe a data de nascimento das criancas' using errcode = '22023';
    end if;
  end loop;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, data_nascimento, tipo,
                         usa_transfer, transfer_origem, email, telefone,
                         categoria_cracha, dificuldade_mobilidade, tem_alergia,
                         alergia_detalhe, precisa_berco, observacoes)
  select
    p_reserva_id,
    trim(x ->> 'nome'),
    nullif(x ->> 'cpf',''),
    nullif(x ->> 'data_nascimento','')::date,
    coalesce(nullif(x ->> 'tipo',''), 'adulto'),
    (x ->> 'usa_transfer')::boolean,
    nullif(x ->> 'transfer_origem',''),
    nullif(x ->> 'email',''),
    nullif(x ->> 'telefone',''),
    'PATROCINADOR',
    coalesce((x ->> 'dificuldade_mobilidade')::boolean, false),
    coalesce((x ->> 'tem_alergia')::boolean, false),
    nullif(x ->> 'alergia_detalhe',''),
    coalesce((x ->> 'precisa_berco')::boolean, false),
    nullif(x ->> 'observacoes','')
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) x;

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status          = case when v_qtd > 0 then 'completo' else 'rascunho' end
  where id = p_reserva_id;

  perform _recalcular_fechado(v_patro);

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd, 'capacidade', v_cap);
end;
$$;

revoke execute on function patro_salvar_quarto(uuid, jsonb, boolean, text) from public, anon;
grant execute on function patro_salvar_quarto(uuid, jsonb, boolean, text) to authenticated, service_role;
