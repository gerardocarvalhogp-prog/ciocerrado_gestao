-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Adiciona "quadruplo" como quarto tipo valido, ao lado de single/
-- duplo/triplo. Pedido do organizador em 01/10/2026.
--
-- "Tipo de quarto" e um conjunto fechado espalhado por 5 CHECK
-- constraints e 8 funcoes com validacao propria (nenhuma le de uma
-- tabela de dominio — e sempre lista literal) — mapeado por completo
-- antes de mexer, pra nao deixar nenhum lugar aceitando quadruplo na
-- entrada e rejeitando/quebrando mais na frente.
--
-- CAPACIDADE: single=1, duplo=2, triplo=3, quadruplo=4 — quando o
-- codigo guarda capacidade na hora de criar/editar o tipo (nao e' so'
-- _capacidade_quarto_patrocinador, varias funcoes tem a MESMA
-- expressao "case p_tipo when 'single' then 1 when 'duplo' then 2
-- else 3" copiada, de antes de "quadruplo" existir — o "else 3" virava
-- o catch-all de "qualquer coisa que nao seja single/duplo", que ate
-- aqui so podia ser triplo. Trocado por "when 'triplo' then 3 when
-- 'quadruplo' then 4 else 3" em todas: nomeia os dois tipos de verdade,
-- e preserva o "else 3" como fallback defensivo pra um tipo
-- desconhecido, igual era antes.
--
-- _capacidade_quarto() (CIO, teto flat de 4 — migration 20260930100000)
-- NAO muda: ja aceita ate 4 pessoas em qualquer tipo de quarto, nao
-- diferencia por tipo. _capacidade_quarto_patrocinador() SIM muda,
-- porque e' especificamente por tipo.
--
-- Cada funcao abaixo e' recriada com o texto EXATO da versao vigente
-- (conferida migration por migration antes desta), trocando so' a(s)
-- linha(s) do check e/ou da capacidade — mesmo padrao que
-- 20260930100000 ja usou. Nenhuma assinatura muda, entao nenhuma
-- precisa de novo grant (create or replace preserva o que ja tem).
-- =====================================================================

set search_path = gestao, public;

-- ---------------------------------------------------------------------
-- 1. CHECK CONSTRAINTS — os 5 lugares onde "tipo" e' coluna de verdade
-- ---------------------------------------------------------------------
alter table quartos drop constraint quartos_tipo_check;
alter table quartos add constraint quartos_tipo_check
  check (tipo = any (array['single','duplo','triplo','quadruplo']));

alter table cota_quartos drop constraint cota_quartos_tipo_check;
alter table cota_quartos add constraint cota_quartos_tipo_check
  check (tipo = any (array['single','duplo','triplo','quadruplo']));

alter table cotas drop constraint cotas_tipo_quarto_padrao_check;
alter table cotas add constraint cotas_tipo_quarto_padrao_check
  check (tipo_quarto_padrao = any (array['single','duplo','triplo','quadruplo']));

alter table reservas drop constraint reservas_tipo_check;
alter table reservas add constraint reservas_tipo_check
  check (tipo = any (array['single','duplo','triplo','quadruplo']));

alter table categorias_quarto drop constraint categorias_quarto_tipo_check;
alter table categorias_quarto add constraint categorias_quarto_tipo_check
  check (tipo in ('single','duplo','triplo','quadruplo'));

-- ---------------------------------------------------------------------
-- 2. CAPACIDADE DO PATROCINADOR POR TIPO
-- ---------------------------------------------------------------------
create or replace function _capacidade_quarto_patrocinador(p_tipo text)
returns int language sql immutable
set search_path = gestao, public as $$
  select case p_tipo
    when 'single' then 1 when 'duplo' then 2
    when 'triplo' then 3 when 'quadruplo' then 4
    else 3 end;
$$;

-- ---------------------------------------------------------------------
-- 3. admin_criar_faixa_quartos — cria o inventario por faixa
-- ---------------------------------------------------------------------
create or replace function admin_criar_faixa_quartos(p_evento_slug text, p_de integer, p_ate integer, p_tipo text, p_bloco text DEFAULT NULL::text)
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare v_evento uuid; v_cap int; v_criados int := 0; v_n int; v_num text;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo invalido' using errcode='22023';
  end if;
  if p_de is null or p_ate is null or p_ate < p_de then
    raise exception 'Faixa invalida' using errcode='22023';
  end if;
  if p_ate - p_de > 500 then
    raise exception 'Faixa muito grande (maximo 500 por vez)'
      using errcode='22023';
  end if;

  v_cap := case p_tipo when 'single' then 1 when 'duplo' then 2
                when 'triplo' then 3 when 'quadruplo' then 4 else 3 end;

  for v_n in p_de .. p_ate loop
    v_num := lpad(v_n::text, 3, '0');
    insert into quartos (evento_id, numero, tipo, capacidade, bloco, status)
    values (v_evento, v_num, p_tipo, v_cap, p_bloco, 'disponivel')
    on conflict do nothing;
    if found then v_criados := v_criados + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'criados', v_criados,
                            'faixa', p_de || '-' || p_ate);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. admin_alterar_tipo_quartos — corrige o tipo de uma faixa ja criada
-- ---------------------------------------------------------------------
create or replace function admin_alterar_tipo_quartos(
  p_evento_slug text,
  p_de text,
  p_ate text,
  p_tipo text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_n int; v_de int; v_ate int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo invalido: %. Use single, duplo, triplo ou quadruplo', p_tipo
      using errcode = '22023';
  end if;

  v_de  := nullif(regexp_replace(coalesce(p_de,''),  '[^0-9]', '', 'g'), '')::int;
  v_ate := nullif(regexp_replace(coalesce(p_ate,''), '[^0-9]', '', 'g'), '')::int;

  if v_de is null or v_ate is null or v_ate < v_de then
    raise exception 'Faixa invalida: de % ate %', p_de, p_ate
      using errcode = '22023';
  end if;

  update quartos q set
    tipo = p_tipo,
    capacidade = case p_tipo when 'single' then 1 when 'duplo' then 2
                      when 'triplo' then 3 when 'quadruplo' then 4 else 3 end
  where q.evento_id = v_evento
    and q.numero ~ '^[0-9]+$'
    and q.numero::int between v_de and v_ate
    and q.tipo <> p_tipo;

  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'alterados', v_n,
                            'de', v_de, 'ate', v_ate, 'tipo', p_tipo);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. admin_editar_tipo_quarto — corrige o tipo de UM apartamento
-- ---------------------------------------------------------------------
create or replace function admin_editar_tipo_quarto(p_id uuid, p_tipo text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_numero text;
begin
  perform _exige_admin();

  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo invalido: %. Use single, duplo, triplo ou quadruplo', p_tipo
      using errcode = '22023';
  end if;

  update quartos set
    tipo = p_tipo,
    capacidade = case p_tipo when 'single' then 1 when 'duplo' then 2
                      when 'triplo' then 3 when 'quadruplo' then 4 else 3 end
  where id = p_id
  returning numero into v_numero;

  if not found then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true, 'numero', v_numero, 'tipo', p_tipo);
end;
$$;

-- ---------------------------------------------------------------------
-- 6. admin_salvar_cota — quartos incluidos por tipo (cota_quartos)
-- ---------------------------------------------------------------------
create or replace function admin_salvar_cota(
  p_evento_slug text, p_nome text, p_ordem integer,
  p_quartos jsonb DEFAULT '{}'::jsonb, p_vagas_mesa integer DEFAULT 0,
  p_reuniao boolean DEFAULT false, p_jantar boolean DEFAULT false,
  p_prazo_indicacao date DEFAULT NULL::date, p_janela_horas integer DEFAULT NULL::integer,
  p_limite_indicacoes integer DEFAULT NULL::integer,
  p_escolhe_convidados boolean DEFAULT true,
  p_upload_logo_qtd integer DEFAULT 0, p_upload_banner boolean DEFAULT false,
  p_upload_arte_revista boolean DEFAULT false, p_upload_apresentacao boolean DEFAULT false,
  p_upload_video boolean DEFAULT false, p_prazo_upload date DEFAULT NULL::date,
  p_valor_sugerido numeric DEFAULT NULL::numeric
) returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
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
  if p_janela_horas is not null and p_janela_horas <= 0 then
    raise exception 'A janela em horas comeca em 1' using errcode='22023';
  end if;
  if p_limite_indicacoes is not null and p_limite_indicacoes < 0 then
    raise exception 'O limite de indicacoes nao pode ser negativo' using errcode='22023';
  end if;
  if coalesce(p_upload_logo_qtd,0) < 0 then
    raise exception 'A quantidade de logos nao pode ser negativa' using errcode='22023';
  end if;

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
                     quartos_incluidos, tipo_quarto_padrao, prazo_indicacao,
                     janela_horas, limite_indicacoes, escolhe_convidados,
                     upload_logo_qtd, upload_banner, upload_arte_revista,
                     upload_apresentacao, upload_video, prazo_upload,
                     valor_sugerido)
  values (v_evento, trim(p_nome), v_ordem, coalesce(p_vagas_mesa,0),
          p_reuniao, p_jantar, 0, 'duplo', p_prazo_indicacao, p_janela_horas,
          p_limite_indicacoes, coalesce(p_escolhe_convidados, true),
          coalesce(p_upload_logo_qtd,0), coalesce(p_upload_banner,false),
          coalesce(p_upload_arte_revista,false), coalesce(p_upload_apresentacao,false),
          coalesce(p_upload_video,false), p_prazo_upload, p_valor_sugerido)
  on conflict (evento_id, nome) do update set
    ordem_prioridade = excluded.ordem_prioridade,
    vagas_mesa_redonda = excluded.vagas_mesa_redonda,
    tem_reuniao_exclusiva = excluded.tem_reuniao_exclusiva,
    tem_jantar = excluded.tem_jantar,
    prazo_indicacao = excluded.prazo_indicacao,
    janela_horas = excluded.janela_horas,
    limite_indicacoes = excluded.limite_indicacoes,
    escolhe_convidados = excluded.escolhe_convidados,
    upload_logo_qtd = excluded.upload_logo_qtd,
    upload_banner = excluded.upload_banner,
    upload_arte_revista = excluded.upload_arte_revista,
    upload_apresentacao = excluded.upload_apresentacao,
    upload_video = excluded.upload_video,
    prazo_upload = excluded.prazo_upload,
    valor_sugerido = excluded.valor_sugerido
  returning id into v_cota;

  delete from cota_quartos where cota_id = v_cota;

  for v_par in
    select key as tipo, (value #>> '{}')::int as qtd
    from jsonb_each(coalesce(p_quartos, '{}'::jsonb))
  loop
    if v_par.tipo not in ('single','duplo','triplo','quadruplo') then
      raise exception 'Tipo de quarto invalido: %', v_par.tipo using errcode='22023';
    end if;
    if coalesce(v_par.qtd,0) > 0 then
      insert into cota_quartos (cota_id, tipo, quantidade)
      values (v_cota, v_par.tipo, v_par.qtd);
      v_total := v_total + v_par.qtd;
    end if;
  end loop;

  update cotas set quartos_incluidos = v_total where id = v_cota;

  return jsonb_build_object('ok', true, 'id', v_cota, 'total_quartos', v_total);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. admin_salvar_categoria_quarto — tipo/capacidade da categoria do resort
-- ---------------------------------------------------------------------
create or replace function admin_salvar_categoria_quarto(
  p_evento_slug text, p_codigo text, p_capacidade integer, p_tipo text
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_n int;
begin
  perform _exige_admin();

  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode='P0002';
  end if;
  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo invalido: %', p_tipo using errcode='22023';
  end if;
  if p_capacidade is null or p_capacidade < 1 or p_capacidade > 6 then
    raise exception 'Capacidade fora do razoavel: %', p_capacidade using errcode='22023';
  end if;

  update categorias_quarto set
    capacidade = p_capacidade, tipo = p_tipo, updated_at = now()
  where evento_id = v_evento and upper(codigo) = upper(trim(p_codigo));

  if not found then
    raise exception 'Categoria % nao encontrada neste evento', p_codigo
      using errcode='P0002';
  end if;

  update quartos q set capacidade = p_capacidade, tipo = p_tipo
   where q.evento_id = v_evento
     and upper(q.categoria) = upper(trim(p_codigo));
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'quartos_atualizados', v_n);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. patro_comprar_quarto / part_comprar_quarto — compra avulsa
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

  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and q.finalidade = 'avulso'
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

  if p_tipo not in ('single','duplo','triplo','quadruplo') then
    raise exception 'Tipo de quarto invalido: %', p_tipo using errcode = '22023';
  end if;

  select evento_id into v_evento from participantes where id = v_part;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and q.finalidade = 'avulso'
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

-- ---------------------------------------------------------------------
-- 9. admin_salvar_quarto_equipe — quarto de equipe/staff (reservas.tipo)
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
  if p_tipo not in ('single','duplo','triplo','quadruplo') then
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
-- autoconfere
-- ---------------------------------------------------------------------
do $$
begin
  if _capacidade_quarto_patrocinador('single') <> 1
     or _capacidade_quarto_patrocinador('duplo') <> 2
     or _capacidade_quarto_patrocinador('triplo') <> 3
     or _capacidade_quarto_patrocinador('quadruplo') <> 4 then
    raise exception 'capacidade do patrocinador por tipo nao bateu com o esperado (single=1, duplo=2, triplo=3, quadruplo=4)';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'quartos_tipo_check'
      and pg_get_constraintdef(oid) ilike '%quadruplo%'
  ) then
    raise exception 'quartos_tipo_check deveria aceitar quadruplo';
  end if;

  raise notice 'quarto "quadruplo": constraints e funcoes conferidas (capacidade=4).';
end $$;
