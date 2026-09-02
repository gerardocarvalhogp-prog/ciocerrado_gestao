-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Quarto extra comprado direto pelo patrocinador nao gerava cobranca.
--
-- part_comprar_quarto/part_cancelar_quarto_extra (lado do CIO) sempre
-- chamaram _recalcular_fatura_participante. As equivalentes do
-- patrocinador — patro_comprar_quarto/patro_cancelar_quarto_extra —
-- nunca chamaram _recalcular_fatura_patrocinador, nos dois sentidos:
-- comprar um quarto a mais nao aparecia na fatura, e cancelar um que
-- ja tinha sido cobrado nao tirava o valor. Achado real, reportado
-- pelo Gerardo (financeiro nao batia pro quarto extra do patrocinador).
-- =====================================================================

set search_path = gestao, public;

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

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', 'Quarto ' || v_seq);
end;
$$;

create or replace function patro_cancelar_quarto_extra(p_reserva_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid; v_quarto uuid; v_origem text;
begin
  select patrocinador_id, quarto_id, origem
    into v_patro, v_quarto, v_origem
  from reservas where id = p_reserva_id;

  perform _exige_patrocinador(v_patro);

  if v_origem <> 'extra' then
    raise exception 'So quarto extra pode ser cancelado pelo portal'
      using errcode = '42501';
  end if;

  update reservas set status = 'cancelado' where id = p_reserva_id;
  update quartos  set status = 'disponivel' where id = v_quarto;

  perform _recalcular_fatura_patrocinador(v_patro);

  return jsonb_build_object('ok', true);
end;
$$;
