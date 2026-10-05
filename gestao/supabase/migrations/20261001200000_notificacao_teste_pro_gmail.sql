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
--
-- v1 desta migration so pegava status 'enfileirada' e deu erro — entre
-- a limpeza da fila e esta migration o organizador ja tinha clicado
-- "Enviar toda a fila" pelo menos uma vez, e o 403 do Resend fez a
-- notificacao virar 'erro' em vez de continuar pendente. Corrigido pra
-- pegar os dois estados e, se achou em 'erro', reabrir pra
-- 'enfileirada' (limpando o erro antigo) pra "Enviar toda a fila"
-- tentar de novo.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_teste uuid;
  v_id uuid;
  v_status_antigo text;
  v_destinatario_antigo text;
begin
  select id into v_evento_teste from eventos where slug = 'teste2027';
  if v_evento_teste is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "teste2027" nao encontrado — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  select id, status, destinatario into v_id, v_status_antigo, v_destinatario_antigo
  from notificacoes
  where status in ('enfileirada','erro') and tipo = 'contrato_assinado' and evento_id = v_evento_teste
  order by created_at desc
  limit 1;

  if v_id is null then
    raise exception 'Nenhuma notificacao contrato_assinado (enfileirada ou com erro) em teste2027 — sumiu de vez?';
  end if;

  update notificacoes set
    destinatario = 'gerardocarvalhogp@gmail.com',
    status = 'enfileirada',
    erro = null
  where id = v_id;

  raise notice 'Notificacao % (estava %) redirecionada de % para gerardocarvalhogp@gmail.com e reaberta para enfileirada.',
    v_id, v_status_antigo, v_destinatario_antigo;
end $$;
