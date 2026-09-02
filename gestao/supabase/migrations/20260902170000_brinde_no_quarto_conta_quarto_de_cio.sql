-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Brinde "entregar no quarto" contava os quartos do PATROCINADOR
-- (reservas.patrocinador_id = a cota dele), nao os quartos dos CIOs —
-- que sao quem de fato recebe o brinde no quarto. O numero exibido
-- ("X quarto(s)") servia pra staff saber se a quantidade que o
-- patrocinador declarou cobre todo mundo; contando os quartos do
-- proprio patrocinador (time dele, nao CIO nenhum) o numero nao dizia
-- nada sobre a cobertura de verdade. Achado real, reportado pelo
-- Gerardo.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_listar_brindes(p_evento_slug text, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
returns table (
  brinde_id uuid, empresa text, cota text, destino text, quartos integer,
  descricao text, quantidade integer, volumes_despachados integer, status text,
  transportadora text, rastreio text, enviado_em timestamptz, recebido_em timestamptz,
  recebido_por text, entregue_em timestamptz, entregue_por text, observacao text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);

  return query
    select b.id, p.empresa, c.nome, b.destino,
           (select count(*)::int from reservas r
             where r.evento_id = e.id
               and r.participante_id is not null
               and r.status <> 'cancelado'),
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
