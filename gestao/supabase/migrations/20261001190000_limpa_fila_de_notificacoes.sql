-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Limpa a fila de notificacoes pendentes (status 'enfileirada') —
-- acumulou lixo de varias rodadas de teste nesta sessao (01/10/2026:
-- reenvio de contrato repetido 4x, sincronizacoes do Sympla, etc.).
-- Pedido do organizador: limpar e deixar so o aviso de contrato
-- assinado do Gerardo em teste2027, que e o que estava sendo testado
-- de verdade (link do rooming, migration anterior).
--
-- So mexe em quem esta 'enfileirada' — notificacao ja 'enviada' ou
-- 'erro' e historico, fica. Mantem TODO aviso 'contrato_assinado' de
-- teste2027 (nao so um, pra nao escolher errado se houver mais de um
-- por engano) e apaga o resto da fila pendente, de qualquer evento.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_teste uuid;
  v_antes int;
  v_mantidos int;
  v_apagados int;
begin
  select id into v_evento_teste from eventos where slug = 'teste2027';
  if v_evento_teste is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Evento "teste2027" nao encontrado — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  select count(*) into v_antes from notificacoes where status = 'enfileirada';

  delete from notificacoes
   where status = 'enfileirada'
     and not (tipo = 'contrato_assinado' and evento_id = v_evento_teste);
  get diagnostics v_apagados = row_count;

  select count(*) into v_mantidos
  from notificacoes
  where status = 'enfileirada' and tipo = 'contrato_assinado' and evento_id = v_evento_teste;

  raise notice 'Fila de notificacoes: % pendente(s) antes, % apagada(s), % mantida(s) (contrato_assinado de teste2027).',
    v_antes, v_apagados, v_mantidos;
end $$;
