-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Quarto para staff e equipe de organizacao.
--
-- O QUE FALTAVA
--
-- `reservas` so admitia dono patrocinador OU participante
-- (`reservas_dono_ck`). Staff da organizacao (coordenacao, seguranca,
-- fotografia...) tambem dorme no resort e ninguem tinha onde registrar
-- isso — nao tem empresa, nao se inscreveu pelo Sympla.
--
-- NAO CRIA TABELA NOVA
--
-- `reservas` + `ocupantes` ja SAO o modelo de "um quarto com gente
-- dentro" — e o mesmo par que atende patrocinador e CIO. Uma tabela de
-- "membros da equipe" seria outra forma de guardar a mesma coisa que
-- `ocupantes` ja guarda (nome, CPF, transfer). O que faltava era so
-- reserva poder existir SEM dono: `origem = 'equipe'` e o rotulo (time
-- ou responsavel, texto livre) faz o papel que "empresa" faz para
-- patrocinador.
--
-- O QUARTO EM SI VEM DO MESMO POOL
--
-- Sem bloco reservado a parte: a alocacao do numero continua na aba
-- Quartos, que ja lista TODA reserva sem numero — a de equipe entra
-- ali de graca, so ensinando `admin_listar_alocacao` a rotular pelo
-- `rotulo` da reserva quando nao ha patrocinador nem participante.
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. RESERVA PODE EXISTIR SEM DONO, SE FOR DE EQUIPE
-- ---------------------------------------------------------------------
alter table reservas drop constraint reservas_dono_ck;
alter table reservas add constraint reservas_dono_ck check (
  (origem = 'equipe' and num_nonnulls(participante_id, patrocinador_id) = 0)
  or
  (origem <> 'equipe' and num_nonnulls(participante_id, patrocinador_id) = 1)
);

alter table reservas drop constraint reservas_origem_check;
alter table reservas add constraint reservas_origem_check
  check (origem in ('cota','inscricao','extra','equipe'));

-- ---------------------------------------------------------------------
-- 2. CRIAR / EDITAR UM QUARTO DE EQUIPE
--
-- "Rotulo" e o time ou o responsavel ("Coordenacao", "Fotografia —
-- Marina"): e como a linha aparece na aba Quartos, no lugar de onde
-- ficaria a empresa.
-- ---------------------------------------------------------------------
create or replace function admin_salvar_quarto_equipe(
  p_evento_slug text,
  p_reserva_id  uuid default null,
  p_rotulo      text default null,
  p_tipo        text default 'duplo'
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_id uuid;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;
  if coalesce(trim(p_rotulo),'') = '' then
    raise exception 'Informe o time ou responsavel' using errcode = '22023';
  end if;
  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo invalido: %', p_tipo using errcode = '22023';
  end if;

  if p_reserva_id is not null then
    update reservas set rotulo = trim(p_rotulo), tipo = p_tipo, updated_at = now()
     where id = p_reserva_id and evento_id = v_evento and origem = 'equipe'
       and status <> 'cancelado'
    returning id into v_id;
    if v_id is null then
      raise exception 'Quarto de equipe nao encontrado' using errcode = 'P0002';
    end if;
  else
    insert into reservas (evento_id, rotulo, tipo, origem, status)
    values (v_evento, trim(p_rotulo), p_tipo, 'equipe', 'rascunho')
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. REMOVER
--
-- Diferente de patrocinador (que bloqueia remocao com quarto
-- preenchido, porque apagar levaria fatura e indicacao junto), aqui nao
-- ha nada pendurado alem dos proprios ocupantes — remover e decisao
-- direta, a tela confirma antes de chamar.
-- ---------------------------------------------------------------------
create or replace function admin_remover_quarto_equipe(p_reserva_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_origem text; v_quarto uuid;
begin
  perform _exige_admin();

  select origem, quarto_id into v_origem, v_quarto
  from reservas where id = p_reserva_id;

  if v_origem is distinct from 'equipe' then
    raise exception 'Quarto de equipe nao encontrado' using errcode = 'P0002';
  end if;

  delete from reservas where id = p_reserva_id;

  if v_quarto is not null then
    update quartos set status = 'disponivel' where id = v_quarto;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. LISTAR, COM OS OCUPANTES JUNTO
-- ---------------------------------------------------------------------
create or replace function admin_listar_quartos_equipe(p_evento_slug text)
returns table (
  reserva_id    uuid,
  rotulo        text,
  tipo          text,
  status        text,
  quarto_id     uuid,
  quarto_numero text,
  ocupantes     jsonb
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select r.id, r.rotulo, r.tipo, r.status, q.id, q.numero,
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', o.id, 'nome', o.nome, 'cpf', o.cpf,
                 'telefone', o.telefone, 'email', o.email,
                 'usa_transfer', o.usa_transfer,
                 'transfer_origem', o.transfer_origem)
               order by o.created_at)
        from ocupantes o where o.reserva_id = r.id
      ), '[]'::jsonb) as ocupantes
    from reservas r
    join eventos e on e.id = r.evento_id and e.slug = p_evento_slug
    left join quartos q on q.id = r.quarto_id
    where r.origem = 'equipe' and r.status <> 'cancelado'
    order by r.rotulo;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. QUEM DORME NO QUARTO
--
-- Mesma logica de `patro_salvar_quarto` (substitui a lista inteira,
-- valida nome e teto de `_capacidade_quarto()`), sem a checagem de
-- dono — quem pode mexer aqui e admin, nao "o patrocinador dono desta
-- reserva".
-- ---------------------------------------------------------------------
create or replace function admin_salvar_ocupantes_equipe(
  p_reserva_id     uuid,
  p_ocupantes      jsonb,
  p_usa_transfer   boolean default null,
  p_transfer_origem text default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_origem text; v_cap int; v_qtd int; v_item jsonb;
begin
  perform _exige_admin();

  select origem into v_origem from reservas
   where id = p_reserva_id and status <> 'cancelado';
  if v_origem is distinct from 'equipe' then
    raise exception 'Quarto de equipe nao encontrado' using errcode = 'P0002';
  end if;

  v_cap := _capacidade_quarto();
  v_qtd := jsonb_array_length(coalesce(p_ocupantes, '[]'::jsonb));
  if v_qtd > v_cap then
    raise exception 'O quarto comporta % pessoa(s); voce enviou %.', v_cap, v_qtd
      using errcode = '22023';
  end if;

  perform _exige_origem_transfer(p_transfer_origem);
  for v_item in select * from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb))
  loop
    if coalesce(trim(v_item ->> 'nome'), '') = '' then
      raise exception 'Todo ocupante precisa de nome' using errcode = '22023';
    end if;
    perform _exige_origem_transfer(nullif(v_item ->> 'transfer_origem',''));
  end loop;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, tipo, usa_transfer,
                         transfer_origem, email, telefone, categoria_cracha)
  select
    p_reserva_id,
    trim(x ->> 'nome'),
    nullif(x ->> 'cpf',''),
    case when o.n = 1 then 'titular' else 'adulto' end,
    (x ->> 'usa_transfer')::boolean,
    nullif(x ->> 'transfer_origem',''),
    nullif(x ->> 'email',''),
    nullif(x ->> 'telefone',''),
    'EQUIPE'
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) with ordinality as o(x, n);

  update reservas set
    usa_transfer    = coalesce(p_usa_transfer, usa_transfer),
    transfer_origem = coalesce(p_transfer_origem, transfer_origem),
    status = case when v_qtd > 0 then 'completo' else 'rascunho' end,
    updated_at = now()
  where id = p_reserva_id;

  return jsonb_build_object('ok', true, 'ocupantes', v_qtd);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. A ABA QUARTOS PASSA A ROTULAR QUEM NAO TEM EMPRESA NEM GESTOR
--
-- Mesma funcao, mesma assinatura — so o COALESCE ganha um terceiro
-- valor. Reservas de equipe nao tem patrocinador nem participante, mas
-- tem rotulo (o time ou responsavel, definido em
-- `admin_salvar_quarto_equipe`).
-- ---------------------------------------------------------------------
create or replace function admin_listar_alocacao(p_evento_slug text, p_apenas_sem_quarto boolean default false)
returns table (ocupante_id uuid, reserva_id uuid, nome text, empresa text, tipo text,
               quarto_id uuid, quarto_numero text, quarto_tipo text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select o.id, r.id, o.nome,
           coalesce(p.empresa, g.empresa, r.rotulo),
           o.tipo, q.id, q.numero, r.tipo
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

-- ---------------------------------------------------------------------
-- 7. PERMISSAO
-- ---------------------------------------------------------------------
revoke execute on function admin_salvar_quarto_equipe(text, uuid, text, text) from public, anon;
revoke execute on function admin_remover_quarto_equipe(uuid) from public, anon;
revoke execute on function admin_listar_quartos_equipe(text) from public, anon;
revoke execute on function admin_salvar_ocupantes_equipe(uuid, jsonb, boolean, text) from public, anon;

grant execute on function admin_salvar_quarto_equipe(text, uuid, text, text) to authenticated, service_role;
grant execute on function admin_remover_quarto_equipe(uuid) to authenticated, service_role;
grant execute on function admin_listar_quartos_equipe(text) to authenticated, service_role;
grant execute on function admin_salvar_ocupantes_equipe(uuid, jsonb, boolean, text) to authenticated, service_role;
