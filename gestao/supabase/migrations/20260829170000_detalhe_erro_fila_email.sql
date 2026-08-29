-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Detalhe dos erros na fila de e-mail — retorno de QA (Cowork, 29/08/2026)
--
-- A tela so mostrava "N com erro" como contador agregado. O texto do
-- erro ja era gravado por notificacao_marcar() desde a fila de email
-- (20260828140000), so que nunca tinha function pra ler de volta —
-- quem via a fila nao tinha como saber SE o problema era, por exemplo,
-- chave do Resend ou destinatario invalido, sem ir direto no banco.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_notificacoes_com_erro(p_limite int default 20)
returns table (
  id uuid,
  destinatario text,
  assunto text,
  tipo text,
  erro text,
  tentativas int,
  created_at timestamptz
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select n.id, n.destinatario, n.assunto, n.tipo, n.erro, n.tentativas, n.created_at
    from notificacoes n
    where n.status = 'erro'
    order by n.created_at desc
    limit greatest(coalesce(p_limite, 20), 1);
end;
$$;

revoke all on function admin_notificacoes_com_erro(int) from public, anon;
grant all on function admin_notificacoes_com_erro(int) to authenticated, service_role;
