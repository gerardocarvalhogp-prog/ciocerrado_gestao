-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Lista quarto por quarto — faltava um jeito de ver/corrigir UM numero
-- sem mexer na faixa inteira.
--
-- O inventario so existia agregado por tipo ("42 duplo, 38 triplo...").
-- Corrigir o tipo de UM apartamento dentro de uma faixa (o quarto 205
-- na faixa 200-279 duplo precisa virar triplo, o resto continua duplo)
-- nao tinha caminho nenhum na tela.
--
-- NAO reaproveita admin_alterar_tipo_quartos com De=Ate=mesmo numero:
-- aquela funcao so casa numero puramente numerico
-- (`q.numero ~ '^[0-9]+$'`, de proposito — e faixa, nao ponto). Quarto
-- com letra ("201A", que o mapa do resort manda de verdade) nunca ia
-- bater nesse regex e a edicao individual voltaria "0 alterado" bem no
-- caso que motivou pedir isso. admin_editar_tipo_quarto edita por id,
-- sem regex de numero — cobre qualquer numeracao.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_listar_quartos_individual(p_evento_slug text, p_busca text default null)
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

revoke execute on function admin_listar_quartos_individual(text, text) from public, anon;
grant execute on function admin_listar_quartos_individual(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Editar UM quarto por id — sem regex de numeracao, cobre "201A"
-- ---------------------------------------------------------------------
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
