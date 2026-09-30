-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Permite ao staff marcar um quarto como "bloqueado" — held back da
-- cota de CIO/patrocinador, por exemplo porque o resort vai vender ele
-- avulso por fora do evento. Pedido do organizador em 30/09/2026.
--
-- O valor 'bloqueado' ja existia no CHECK de quartos.status e ja era
-- filtrado por admin_quartos_livres (nunca aparecia pra atribuir a
-- uma reserva) — so faltava uma funcao que escrevesse esse valor.
-- Nenhuma function ou tela fazia isso ate agora.
--
-- Nao deixa bloquear/desbloquear quarto que tem reserva ativa: o
-- status dele e' derivado (reservado) e so muda via admin_alocar_quarto
-- (liberar a reserva primeiro). Sem essa trava, dava pra bloquear um
-- quarto ocupado e status ficaria discordando de reservas.quarto_id.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_definir_status_quarto(p_id uuid, p_status text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_evento uuid; v_status_atual text; v_ocupado boolean;
begin
  perform _exige_staff();

  if p_status not in ('disponivel', 'bloqueado') then
    raise exception 'Status invalido: %. Use disponivel ou bloqueado — reservado e automatico, via atribuicao de quarto.', p_status
      using errcode = '22023';
  end if;

  select evento_id, status into v_evento, v_status_atual from quartos where id = p_id;
  if v_evento is null then
    raise exception 'Quarto nao encontrado' using errcode = 'P0002';
  end if;

  select exists(select 1 from reservas r
                where r.quarto_id = p_id and r.status <> 'cancelado')
    into v_ocupado;

  if v_ocupado then
    raise exception 'Este quarto esta atribuido a uma reserva — libere a atribuicao antes de mudar o status'
      using errcode = '55000';
  end if;

  update quartos set status = p_status where id = p_id;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

revoke execute on function admin_definir_status_quarto(uuid, text) from public, anon;
grant execute on function admin_definir_status_quarto(uuid, text) to authenticated, service_role;
