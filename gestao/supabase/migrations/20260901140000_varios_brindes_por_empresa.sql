-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Volta a permitir mais de um brinde por empresa — decisao explicita
-- do usuario, revertendo a consolidacao de 26/08
-- (20260826110000_brinde_da_empresa.sql).
--
-- POR QUE VOLTOU
--
-- A consolidacao de 26/08 resolveu um problema real (brinde por
-- QUARTO obrigava responder a mesma pergunta 8 vezes, com resposta
-- podendo divergir entre quartos). Mas empresa que manda mais de um
-- TIPO de brinde (caneca E camiseta, por exemplo) tambem e caso
-- legitimo, e "um brinde por empresa" nao deixava. A pedido do
-- usuario, volta a ser "quantos brindes DISTINTOS a empresa quiser",
-- so que agora por TIPO de brinde, nao por quarto — nao reabre o
-- problema original.
--
-- O QUE MUDA
--
-- - `brindes_patrocinador_uk` (unique em patrocinador_id) sai.
-- - `volumes_despachados`: quantos volumes fisicos foram despachados
--   (2 caixas), separado de `quantidade` (60 canecas — item, nao
--   embalagem).
-- - patro_salvar_brinde ganha p_id: null cria um brinde novo,
--   preenchido edita o que ja existe (e so o dono).
-- - patro_meu_brinde (retornava UM brinde com to_jsonb) vira
--   patro_listar_brindes (retorna QUALQUER quantidade) +
--   patro_prever_custo_brinde (so o preview de custo, que nao
--   pertence a nenhum brinde especifico).
-- - patro_remover_brinde: cancela um brinde ainda 'prometido' (depois
--   que a organizacao ja mexeu nele, cancelar exige falar com a
--   organizacao, nao um DELETE aqui).
--
-- O QUE NAO MUDA
--
-- - patro_informar_rastreio ja atualizava TODOS os brindes pendentes
--   de uma vez ("a empresa nao posta uma caixa por quarto, posta uma
--   caixa com tudo") — esse comportamento ja era multi-linha, nao
--   precisa mudar.
-- - A cobranca de entrega no quarto (_recalcular_fatura_patrocinador)
--   usa EXISTS, nao COUNT — continua cobrando uma vez por quarto
--   visitado, nao uma vez por brinde. Nao muda com mais linhas.
-- =====================================================================

set search_path = gestao, public;

alter table brindes add column if not exists volumes_despachados integer;
comment on column brindes.volumes_despachados is
  'Quantos volumes fisicos foram despachados (2 caixas) — diferente de quantidade, que e item (60 canecas).';

drop index if exists brindes_patrocinador_uk;

-- ---------------------------------------------------------------------
-- 1. CRIAR OU EDITAR — p_id null cria, preenchido edita o proprio
-- ---------------------------------------------------------------------
drop function if exists patro_salvar_brinde(uuid, boolean, text, integer, text);

create or replace function patro_salvar_brinde(
  p_patrocinador_id uuid,
  p_vai_enviar boolean,
  p_descricao text default null,
  p_quantidade integer default null,
  p_destino text default 'stand',
  p_id uuid default null,
  p_volumes_despachados integer default null
) returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_id uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);

  if p_destino not in ('stand','quarto') then
    raise exception 'Destino invalido: %. Use stand ou quarto', p_destino
      using errcode = '22023';
  end if;
  if coalesce(p_vai_enviar,false) and coalesce(trim(p_descricao),'') = '' then
    raise exception 'Diga o que e o brinde' using errcode = '22023';
  end if;

  if p_id is not null then
    update brindes set
      vai_enviar = coalesce(p_vai_enviar,false),
      descricao  = nullif(trim(p_descricao),''),
      quantidade = p_quantidade,
      destino    = p_destino,
      volumes_despachados = p_volumes_despachados,
      updated_at = now()
    where id = p_id and patrocinador_id = p_patrocinador_id
    returning id into v_id;

    if v_id is null then
      raise exception 'Brinde nao encontrado' using errcode = 'P0002';
    end if;
  else
    insert into brindes (patrocinador_id, vai_enviar, descricao, quantidade,
                         destino, volumes_despachados)
    values (p_patrocinador_id, coalesce(p_vai_enviar,false),
            nullif(trim(p_descricao),''), p_quantidade, p_destino,
            p_volumes_despachados)
    returning id into v_id;
  end if;

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. LISTAR (substitui patro_meu_brinde, que so servia pra 1 linha)
-- ---------------------------------------------------------------------
drop function if exists patro_meu_brinde(uuid);

create or replace function patro_listar_brindes(p_patrocinador_id uuid)
returns table (
  id uuid, vai_enviar boolean, descricao text, quantidade integer,
  volumes_despachados integer, destino text, status text,
  transportadora text, rastreio text,
  enviado_em timestamptz, recebido_em timestamptz, entregue_em timestamptz
) language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select b.id, b.vai_enviar, b.descricao, b.quantidade, b.volumes_despachados,
           b.destino, b.status, b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.entregue_em
    from brindes b
    where b.patrocinador_id = p_patrocinador_id
      and b.status <> 'cancelado'
    order by b.created_at;
end;
$$;

create or replace function patro_prever_custo_brinde(p_patrocinador_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_quartos int; v_preco numeric(12,2); v_evento uuid;
begin
  perform _exige_patrocinador(p_patrocinador_id);
  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  select count(*) into v_quartos from reservas r
   where r.patrocinador_id = p_patrocinador_id and r.status <> 'cancelado';
  v_preco := _preco_item(v_evento, 'entrega_brinde_quarto');
  return jsonb_build_object('quartos', v_quartos, 'preco_entrega', v_preco,
                            'custo_se_quarto', v_quartos * v_preco);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. REMOVER — so enquanto ninguem ainda mexeu (status = prometido)
-- ---------------------------------------------------------------------
create or replace function patro_remover_brinde(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid; v_status text;
begin
  select patrocinador_id, status into v_patro, v_status from brindes where id = p_id;
  if v_patro is null then
    raise exception 'Brinde nao encontrado' using errcode = 'P0002';
  end if;
  perform _exige_patrocinador(v_patro);

  if v_status <> 'prometido' then
    raise exception 'Este brinde ja esta em % — fale com a organizacao pra cancelar', v_status
      using errcode = '55000';
  end if;

  delete from brindes where id = p_id;
  perform _recalcular_fatura_patrocinador(v_patro);

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. admin_listar_brindes ganha volumes_despachados
-- ---------------------------------------------------------------------
drop function if exists admin_listar_brindes(text, text, integer, integer);

create or replace function admin_listar_brindes(p_evento_slug text, p_status text default null, p_limite integer default 500, p_offset integer default 0)
returns table (
  brinde_id uuid, empresa text, cota text, destino text, quartos integer,
  descricao text, quantidade integer, volumes_despachados integer, status text,
  transportadora text, rastreio text,
  enviado_em timestamptz, recebido_em timestamptz, recebido_por text,
  entregue_em timestamptz, entregue_por text, observacao text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  return query
    select b.id, p.empresa, c.nome, b.destino,
           (select count(*)::int from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           b.descricao, b.quantidade, b.volumes_despachados, b.status,
           b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.recebido_por,
           b.entregue_em, b.entregue_por, b.observacao
    from brindes b
    join patrocinadores p on p.id = b.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    where b.vai_enviar
      and (p_status is null or b.status = p_status)
    order by case b.status
               when 'prometido' then 1 when 'enviado' then 2
               when 'recebido'  then 3 when 'entregue' then 4
               else 5 end,
             case b.destino when 'quarto' then 1 else 2 end,
             p.empresa
    limit greatest(coalesce(p_limite, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

revoke execute on function patro_salvar_brinde(uuid,boolean,text,integer,text,uuid,integer) from public, anon;
revoke execute on function patro_listar_brindes(uuid) from public, anon;
revoke execute on function patro_prever_custo_brinde(uuid) from public, anon;
revoke execute on function patro_remover_brinde(uuid) from public, anon;
revoke execute on function admin_listar_brindes(text,text,integer,integer) from public, anon;
grant execute on function patro_salvar_brinde(uuid,boolean,text,integer,text,uuid,integer) to authenticated, service_role;
grant execute on function patro_listar_brindes(uuid) to authenticated, service_role;
grant execute on function patro_prever_custo_brinde(uuid) to authenticated, service_role;
grant execute on function patro_remover_brinde(uuid) to authenticated, service_role;
grant execute on function admin_listar_brindes(text,text,integer,integer) to authenticated, service_role;
