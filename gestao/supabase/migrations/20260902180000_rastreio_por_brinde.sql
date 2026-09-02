-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Rastreio de envio passa a ser por brinde, nao por empresa inteira.
--
-- patro_informar_rastreio aplicava o mesmo codigo a TODOS os brindes
-- pendentes da empresa de uma vez — desenho de quando so existia um
-- brinde por empresa (documentado na migration de origem, 20260825100000).
-- Desde que "varios brindes por empresa" voltou (20260901140000, cada
-- brinde com transportadora/rastreio proprios na tabela), aplicar um
-- codigo so pra tudo ficou errado: camiseta e caneca podem sair em
-- caixas separadas, com rastreio diferente. Achado real, reportado
-- pelo Gerardo — "os dados do envio tem que estar associado ao brinde".
--
-- patro_listar_brindes ja devolvia transportadora/rastreio por linha;
-- a tela e que nunca mostrava (proximo commit, front-end).
-- =====================================================================

set search_path = gestao, public;

drop function if exists patro_informar_rastreio(uuid, text, text);

create or replace function patro_informar_rastreio(p_id uuid, p_transportadora text, p_rastreio text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_patro uuid; v_status text;
begin
  select patrocinador_id, status into v_patro, v_status from brindes where id = p_id;
  if v_patro is null then
    raise exception 'Brinde nao encontrado' using errcode = 'P0002';
  end if;

  perform _exige_patrocinador(v_patro);

  if coalesce(trim(p_rastreio),'') = '' then
    raise exception 'Informe o codigo de rastreio' using errcode = '22023';
  end if;
  if v_status not in ('prometido','enviado') then
    raise exception 'Esse brinde ja passou da etapa de envio' using errcode = '55000';
  end if;

  -- `enviado` tambem entra: corrigir um codigo digitado errado e caso
  -- comum, e obrigar a organizacao a desfazer seria pior.
  update brindes set
    transportadora = nullif(trim(p_transportadora),''),
    rastreio       = trim(p_rastreio),
    status         = 'enviado',
    enviado_em     = coalesce(enviado_em, now()),
    updated_at     = now()
  where id = p_id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function patro_informar_rastreio(uuid,text,text) from public, anon;
grant execute on function patro_informar_rastreio(uuid,text,text) to authenticated, service_role;
