-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Redireciona SO a notificacao de teste (contrato_assinado, teste2027,
-- mantida na limpeza da fila em 20261001190000) pro gmail pessoal do
-- organizador — o Resend recusa mandar pra qualquer outro endereco
-- ("You can only send testing emails to your own email address")
-- enquanto o dominio ciocerrado.com.br nao for verificado la (pendencia
-- ja registrada em CLAUDE.md). Pedido do organizador em 01/10/2026,
-- so pra conseguir ver o texto/link de verdade clicando "Enviar toda a
-- fila" sem esperar a verificacao do dominio.
--
-- So essa UMA notificacao, so por enquanto: nao muda nada permanente
-- no sistema, nao mexe no destinatario de producao (continuaria indo
-- pro gestor de verdade assim que o dominio for verificado e
-- contratos reais passarem a gerar o aviso).
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_teste uuid;
  v_id uuid;
  v_destinatario_antigo text;
begin
  select id into v_evento_teste from eventos where slug = 'teste2027';
  if v_evento_teste is null then
    raise exception 'Evento "teste2027" nao encontrado';
  end if;

  select id, destinatario into v_id, v_destinatario_antigo
  from notificacoes
  where status = 'enfileirada' and tipo = 'contrato_assinado' and evento_id = v_evento_teste
  order by created_at desc
  limit 1;

  if v_id is null then
    raise exception 'Nenhuma notificacao contrato_assinado pendente em teste2027 — a fila ja foi esvaziada ou enviada?';
  end if;

  update notificacoes set destinatario = 'gerardocarvalhogp@gmail.com'
   where id = v_id;

  raise notice 'Notificacao % redirecionada de % para gerardocarvalhogp@gmail.com.', v_id, v_destinatario_antigo;
end $$;
