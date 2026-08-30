-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — fase 3c: WhatsApp
--
-- So a base de dados e a fila. Nao tem como isso funcionar de verdade
-- ainda — falta, fora deste banco:
--   1. Verificacao de negocio no WhatsApp Business Platform (Meta)
--   2. Numero de telefone dedicado, aprovado
--   3. Template de mensagem aprovado pelo Meta (toda mensagem fora de
--      uma janela de 24h iniciada pelo destinatario PRECISA ser
--      template pre-aprovado — nao da pra mandar texto livre)
--   4. Escolher o provedor: Cloud API da Meta direto, ou um BSP
--      (Twilio/Zenvia/Gupshup) por cima dela
--   5. Opt-in explicito de quem recebe (LGPD + politica do WhatsApp) —
--      o consentimento que ja existe (participante_perfil) e sobre uso
--      analitico da pesquisa, nao serve pra canal de contato
--
-- Quando isso existir, `enviar-whatsapp` (Edge Function irma de
-- enviar-notificacoes) le daqui e dispara pra valer.
--
-- notificacoes.destinatario, pro canal whatsapp, guarda o telefone em
-- E.164 (+55...) em vez de e-mail — mesmo campo, formato diferente
-- conforme o canal, pra nao duplicar a tabela inteira por causa de um
-- canal a mais.
-- =====================================================================

set search_path = gestao, public;

alter table notificacoes add column if not exists canal text not null default 'email';
alter table notificacoes add constraint notificacoes_canal_check
  check (canal = any (array['email','whatsapp']));

alter table notificacoes add column if not exists template_nome text;
alter table notificacoes add column if not exists template_params jsonb;

comment on column notificacoes.canal is
  'email ou whatsapp. Para whatsapp, destinatario guarda telefone em E.164, nao e-mail.';
comment on column notificacoes.template_nome is
  'Nome do template aprovado no WhatsApp Business Platform. So usado quando canal=whatsapp.';
comment on column notificacoes.template_params is
  'Parametros posicionais do template, na ordem que o Meta espera. Ex: ["Fulano", "3 dias"].';

-- notificacoes_pendentes ganha filtro por canal — sem isso,
-- enviar-notificacoes (Resend) e o futuro enviar-whatsapp iam
-- competir pela mesma fila e cada um tentaria mandar linha do canal
-- errado. Assinatura muda (parametro e colunas novas) e o argumento
-- extra criaria uma sobrecarga ambigua ao lado da antiga — dropa antes.
drop function if exists notificacoes_pendentes(integer, uuid);

create or replace function notificacoes_pendentes(
  p_limite integer default 50, p_id uuid default null, p_canal text default 'email'
) returns table(id uuid, destinatario text, assunto text, corpo text, tipo text,
                canal text, template_nome text, template_params jsonb)
language plpgsql security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select n.id, n.destinatario, n.assunto, n.corpo, n.tipo,
           n.canal, n.template_nome, n.template_params
    from notificacoes n
    where n.status = 'enfileirada'
      and n.canal = coalesce(p_canal, 'email')
      and coalesce(trim(n.destinatario),'') <> ''
      and (p_id is null or n.id = p_id)
      and (p_id is not null or n.tentativas < 3)
    order by n.created_at
    limit case when p_id is not null then 1 else p_limite end;
end;
$$;

revoke all on function notificacoes_pendentes(integer,uuid,text) from public, anon;
grant all on function notificacoes_pendentes(integer,uuid,text) to authenticated, service_role;
