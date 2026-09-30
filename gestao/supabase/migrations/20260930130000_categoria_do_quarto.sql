-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_listar_quartos_individual passa a devolver, alem do status
-- bruto (disponivel/reservado/bloqueado), pra quem o quarto e —
-- pedido do organizador em 30/09/2026, pra tela mostrar "Patrocinador"
-- / "CIO" / "Organização / Staff" / "Avulso" em vez de so "reservado",
-- que nao dizia quem estava dentro.
--
-- Deriva de reservas.patrocinador_id / participante_id / origem, que
-- ja existem e ja sao a fonte de verdade (`reservas_dono_ck`, migration
-- 20260831140000) — nao cria coluna nova em `quartos`. Quarto sem
-- reserva ativa (nenhuma linha casa no left join) cai em 'avulso',
-- nao importa se o status interno e 'disponivel' ou 'bloqueado': dos
-- dois jeitos ninguem do evento esta reservado ali.
-- =====================================================================

set search_path = gestao, public;

drop function if exists admin_listar_quartos_individual(text, text);

create function admin_listar_quartos_individual(p_evento_slug text, p_busca text DEFAULT NULL::text)
returns table (
  id uuid, numero text, tipo text, capacidade integer, status text,
  bloco text, andar text, corredor text, categoria text,
  reserva_id uuid, ocupado_por text, finalidade text
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
           coalesce(r.ocupado_por, p.empresa, g.empresa, r.rotulo),
           case
             when r.patrocinador_id is not null then 'patrocinador'
             when r.participante_id  is not null then 'cio'
             when r.origem = 'equipe' then 'equipe'
             else 'avulso'
           end
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
