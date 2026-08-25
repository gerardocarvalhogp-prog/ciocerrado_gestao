-- =====================================================================
-- CORRECAO PARA O BANCO HOSPEDADO  ·  desfazer check-in com rastro
--
-- Este arquivo sobe para o remoto a UNICA coisa em que a linhagem local
-- estava na frente. Depois dele, o local passa a ser um espelho do
-- hospedado (ver LEIA-ME.md desta pasta).
--
-- DOIS DEFEITOS NO REMOTO
--
-- 1. `checkin_desfazer` devolve {"ok": true} mesmo quando nao desfez
--    nada — id inexistente ou check-in ja desfeito passam calados. Quem
--    esta na portaria ve "desfeito" e segue, sem ter desfeito.
--
-- 2. Nao guarda QUEM desfez. O README promete que "check-in desfeito nao
--    e apagado, ganha desfeito_em — os relatorios ignoram, mas a
--    auditoria mantem". Auditoria sem autor e metade de uma auditoria:
--    da para saber que alguem liberou a pessoa, nao quem.
--
-- A versao local ja resolvia os dois. E ela que vai aqui.
-- =====================================================================

set search_path = gestao, public;

alter table checkins add column if not exists desfeito_por text;

comment on column checkins.desfeito_por is
  'E-mail de quem desfez o check-in. Auditoria: o registro nao e apagado, so marcado.';

create or replace function checkin_desfazer(p_checkin_id uuid)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_n int;
begin
  perform _exige_staff();

  update checkins
     set desfeito_em = now(),
         desfeito_por = auth.jwt() ->> 'email'
   where id = p_checkin_id and desfeito_em is null;

  -- sem isso, desfazer duas vezes (ou um id errado) devolve sucesso
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'Check-in nao encontrado ou ja desfeito.' using errcode = 'P0002';
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function checkin_desfazer(uuid) from public, anon;
grant execute on function checkin_desfazer(uuid) to authenticated, service_role;
