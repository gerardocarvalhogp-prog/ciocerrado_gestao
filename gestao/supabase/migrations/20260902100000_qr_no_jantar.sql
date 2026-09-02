-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- QR Code no jantar: cracha de mesa com QR + check-in lendo o QR.
--
-- O jantar nunca teve QR porque jantar_convidados nao passa por
-- v_esperados/v_etiquetas (aquele sistema depende de reserva/evento_id,
-- que jantar nao tem — comentario ja deixado em jantares.html). Em vez
-- de forcar o jantar dentro daquele sistema, o QR do jantar carrega seu
-- proprio prefixo ("jantar_convidado:<uuid>", chave primaria de
-- jantar_convidados — ja e globalmente unica, nao precisa do jantar_id
-- junto) e ganha sua propria funcao de leitura.
--
-- jantar_checkin_registrar (clique manual na lista) continua existindo
-- do jeito que esta — erro se ja tinha check-in, do jeito que a tela
-- ja trata (botao vira "desfazer" antes de dar tempo de clicar de
-- novo). A leitura por QR pode escanear o mesmo cracha duas vezes sem
-- querer, e ai precisa do mesmo "ja_estava: true" sem erro que o
-- checkin_registrar geral ja usa.
-- =====================================================================

set search_path = gestao, public;

create or replace function jantar_checkin_por_qr(p_pessoa_key text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare
  v_id     uuid;
  v_nome   text;
  v_status text;
  v_ja     timestamptz;
begin
  perform _exige_staff();

  if p_pessoa_key !~ '^jantar_convidado:' then
    raise exception 'Esse crachá não é de um convidado de jantar' using errcode = '22023';
  end if;
  v_id := substring(p_pessoa_key from 18)::uuid;

  select jc.status, g.nome, jc.updated_at
    into v_status, v_nome, v_ja
  from jantar_convidados jc
  join gestores g on g.id = jc.gestor_id
  where jc.id = v_id;

  if v_nome is null then
    raise exception 'Convidado não encontrado' using errcode = 'P0002';
  end if;

  if v_status = 'compareceu' then
    return jsonb_build_object('ok', true, 'ja_estava', true, 'nome', v_nome, 'registrado_em', v_ja);
  end if;

  update jantar_convidados set status = 'compareceu' where id = v_id;

  return jsonb_build_object('ok', true, 'ja_estava', false, 'nome', v_nome);
end;
$$;

revoke execute on function jantar_checkin_por_qr(text) from public, anon;
grant execute on function jantar_checkin_por_qr(text) to authenticated, service_role;
