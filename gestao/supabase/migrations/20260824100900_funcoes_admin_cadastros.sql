-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-admin-cadastros.sql  ·  evento, cotas, patrocinadores, quartos
--
-- Roda DEPOIS de funcoes-admin.sql.
--
-- E a aba "Estrutura" mais a aba "Patrocinadores". Nada aqui e do dia
-- do evento: e o que precisa estar pronto antes de abrir o portal.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 1. EVENTO
-- =====================================================================


-- =====================================================================
-- 2. COTAS
-- =====================================================================


create or replace function admin_remover_cota(p_cota_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare v_n int;
begin
  perform exigir_admin();

  select count(*) into v_n from patrocinadores where cota_id = p_cota_id;
  if v_n > 0 then
    raise exception 'A cota tem % patrocinador(es). Mova-os antes de remove-la.', v_n;
  end if;

  delete from cotas where id = p_cota_id;
  return jsonb_build_object('ok', true);
end;
$$;


-- =====================================================================
-- 3. PATROCINADORES
-- =====================================================================


create or replace function admin_remover_patrocinador(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare v_ocup int;
begin
  perform exigir_admin();

  -- reserva com gente dentro nao some por um clique: e rooming ja
  -- preenchido pela empresa
  select count(*) into v_ocup
  from ocupantes o join reservas r on r.id = o.reserva_id
  where r.patrocinador_id = p_id and r.status <> 'cancelado';

  if v_ocup > 0 then
    raise exception
      'Esta empresa ja tem % ocupante(s) no rooming. Inative-a em vez de remover.', v_ocup;
  end if;

  delete from patrocinadores where id = p_id;
  if not found then raise exception 'Patrocinador nao encontrado.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 4. USUARIOS DO PATROCINADOR
-- =====================================================================

create or replace function admin_listar_usuarios_patro(p_patrocinador_id uuid)
returns table (id uuid, email text, nome text, telefone text,
               created_at timestamptz)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  return query
  select u.id, u.email, u.nome, u.telefone, u.created_at
  from usuarios_patrocinador u
  where u.patrocinador_id = p_patrocinador_id and u.ativo
  order by u.email;
end;
$$;

create or replace function admin_salvar_usuario_patro(
  p_patrocinador_id uuid, p_email text,
  p_nome text default null, p_telefone text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform exigir_admin();

  p_email := nullif(trim(coalesce(p_email,'')),'');
  if p_email is null then raise exception 'Informe o e-mail.'; end if;
  if norm_doc(p_email) !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'E-mail invalido: um endereco errado vira acesso que nunca funciona.';
  end if;
  if not exists (select 1 from patrocinadores where id = p_patrocinador_id) then
    raise exception 'Patrocinador nao encontrado.';
  end if;

  insert into usuarios_patrocinador (patrocinador_id, email, nome, telefone, ativo)
  values (p_patrocinador_id, p_email, p_nome, p_telefone, true)
  on conflict (patrocinador_id, email_norm) do update
    set nome = coalesce(excluded.nome, usuarios_patrocinador.nome),
        telefone = coalesce(excluded.telefone, usuarios_patrocinador.telefone),
        ativo = true
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function admin_remover_usuario_patro(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
begin
  perform exigir_admin();
  update usuarios_patrocinador set ativo = false where id = p_id;
  if not found then raise exception 'Usuario nao encontrado.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 5. INVENTARIO DE QUARTOS
-- =====================================================================

create or replace function admin_resumo_quartos(p_evento_slug text)
returns table (tipo text, total bigint, livres bigint, ocupados bigint)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  perform exigir_staff();
  return query
  select q.tipo,
         count(*),
         count(*) filter (where not exists (
           select 1 from reservas r where r.quarto_id = q.id and r.status <> 'cancelado')),
         count(*) filter (where exists (
           select 1 from reservas r where r.quarto_id = q.id and r.status <> 'cancelado'))
  from quartos q
  where q.evento_id = evento_id_por_slug(p_evento_slug)
  group by q.tipo
  order by q.tipo;
end;
$$;

-- Cria os quartos de uma faixa de numeracao (200 a 279, por exemplo).
--
-- Repetido e ignorado, nao e erro: recriar a faixa depois de acrescentar
-- alguns quartos e o uso normal. O indice unico (evento, numero) e quem
-- garante isso.
create or replace function admin_criar_faixa_quartos(
  p_evento_slug text, p_de int, p_ate int,
  p_tipo text default 'duplo', p_bloco text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_n int := 0;
begin
  perform exigir_admin();

  v_evento := evento_id_por_slug(p_evento_slug);
  if v_evento is null then raise exception 'Evento nao encontrado.'; end if;
  if p_de is null or p_ate is null then raise exception 'Informe a faixa.'; end if;
  if p_ate < p_de then raise exception 'O numero final e menor que o inicial.'; end if;
  if p_ate - p_de > 2000 then
    raise exception 'Faixa longa demais (% quartos). Divida em partes.', p_ate - p_de + 1;
  end if;
  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido.';
  end if;

  insert into quartos (evento_id, numero, tipo, capacidade, bloco, status)
  select v_evento, n::text, p_tipo, cap_tipo(p_tipo), p_bloco, 'disponivel'
  from generate_series(p_de, p_ate) n
  on conflict do nothing;

  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'criados', v_n,
                            'faixa', p_de || '-' || p_ate);
end;
$$;

-- Gera as reservas que cada patrocinador vai preencher no portal.
--
-- Sem este passo o patrocinador entra e ve "sua cota ainda nao tem
-- quartos liberados". Cria a diferenca entre o que a cota da (mais os
-- extras da empresa) e o que a empresa ja tem - rodar duas vezes nao
-- duplica.
--
-- A reserva nasce SEM quarto fisico: o numero so entra quando o resort
-- libera o espelho, na aba Separar quartos.
create or replace function admin_gerar_quartos_todos(p_evento_slug text)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  p record;
  t record;
  v_tem int;
  v_falta int;
  v_seq int;
  v_criadas int := 0;
begin
  perform exigir_admin();

  v_evento := evento_id_por_slug(p_evento_slug);
  if v_evento is null then raise exception 'Evento nao encontrado.'; end if;

  for p in
    select pt.id, pt.empresa, pt.quartos_extras_cota,
           pt.cota_id, c.tipo_quarto_padrao
    from patrocinadores pt
    join cotas c on c.id = pt.cota_id
    where pt.evento_id = v_evento and pt.status = 'ativo'
  loop
    -- a composicao da cota, tipo a tipo. Vem de cota_quartos
    -- (migracao-02): a cota pode misturar tipos, como 2 duplos + 2
    -- singles, e um contador unico nao diria quais.
    for t in
      select cq.tipo, cq.quantidade as qtd
      from cota_quartos cq
      where cq.cota_id = p.cota_id and cq.quantidade > 0
    loop
      select count(*) into v_tem
      from reservas r
      where r.patrocinador_id = p.id
        and r.tipo = t.tipo
        and r.origem = 'cota'
        and r.status <> 'cancelado';

      v_falta := greatest(t.qtd - v_tem, 0);

      while v_falta > 0 loop
        select count(*)+1 into v_seq from reservas
        where patrocinador_id = p.id and status <> 'cancelado';

        insert into reservas (evento_id, patrocinador_id, rotulo, tipo,
                              origem, status)
        values (v_evento, p.id, 'Quarto ' || v_seq, t.tipo, 'cota', 'rascunho');

        v_criadas := v_criadas + 1;
        v_falta := v_falta - 1;
      end loop;
    end loop;

    -- excecao por empresa (ex.: uma vaga extra negociada no contrato)
    if coalesce(p.quartos_extras_cota,0) > 0 then
      select count(*) into v_tem
      from reservas r
      where r.patrocinador_id = p.id
        and r.origem = 'extra'
        and r.status <> 'cancelado';

      v_falta := greatest(p.quartos_extras_cota - v_tem, 0);

      while v_falta > 0 loop
        select count(*)+1 into v_seq from reservas
        where patrocinador_id = p.id and status <> 'cancelado';

        insert into reservas (evento_id, patrocinador_id, rotulo,
                              tipo, origem, status)
        values (v_evento, p.id, 'Quarto ' || v_seq,
                coalesce(p.tipo_quarto_padrao,'duplo'), 'extra', 'rascunho');

        v_criadas := v_criadas + 1;
        v_falta := v_falta - 1;
      end loop;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'reservas_criadas', v_criadas);
end;
$$;

-- =====================================================================
-- 6. PERMISSOES
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao' and p.proname like 'admin%'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
