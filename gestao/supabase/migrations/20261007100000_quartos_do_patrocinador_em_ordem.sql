-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Quartos do patrocinador em ordem no portal.
--
-- Achado da analise de design de 07/10/2026: o portal mostrava "Quarto 2,
-- Quarto 1, Quarto 3". patro_listar_quartos ordenava so por created_at,
-- e os quartos da cota nascem juntos (admin_gerar_quartos_cota, numa
-- transacao so — mesmo created_at), entao a ordem saia arbitraria.
-- Agora: os da cota primeiro, os extras depois, cada grupo pelo numero
-- do rotulo.
-- =====================================================================

set search_path = gestao, public;

CREATE OR REPLACE FUNCTION gestao.patro_listar_quartos(p_patrocinador_id uuid)
 RETURNS TABLE(reserva_id uuid, rotulo text, tipo text, origem text, capacidade integer, ocupantes integer, usa_transfer boolean, transfer_origem text, status text, quarto_numero text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'gestao', 'public'
AS $function$
begin
  perform _exige_patrocinador(p_patrocinador_id);
  return query
    select r.id, r.rotulo, r.tipo, r.origem,
           _capacidade_quarto_patrocinador(r.tipo),
           (select count(*)::int from ocupantes o where o.reserva_id = r.id),
           r.usa_transfer, r.transfer_origem, r.status, q.numero
    from reservas r
    left join quartos q on q.id = r.quarto_id
    where r.patrocinador_id = p_patrocinador_id
      and r.status <> 'cancelado'
    -- cota antes de extra; dentro de cada um, pelo numero do rotulo
    -- ("Quarto 2" antes de "Quarto 10"); created_at so desempata
    order by (r.origem = 'extra'),
             nullif(regexp_replace(coalesce(r.rotulo,''), '\D', '', 'g'), '')::int nulls last,
             r.rotulo, r.created_at;
end;
$function$;
