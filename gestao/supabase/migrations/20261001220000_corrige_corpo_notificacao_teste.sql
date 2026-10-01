-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- A notificacao de teste (contrato_assinado, redirecionada pro gmail
-- em 20261001200000) foi criada pelo PRIMEIRO teste do webhook —
-- antes de 20261001180000 (que ensinou webhook_contrato_assinado a
-- gravar o corpo com o link). Corpo ficou null desde entao; as
-- migrations seguintes mudaram destinatario/status mas nunca
-- preencheram o texto. O e-mail saiu generico, sem link — confirmado
-- pelo organizador (print do Gmail, 01/10/2026).
--
-- Preenche na mao, com o MESMO texto que webhook_contrato_assinado ja
-- gera pra contrato novo a partir de agora — so esta linha antiga
-- precisava do empurrao retroativo.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_teste uuid;
  v_evento_slug text;
  v_id uuid;
  v_nome text;
begin
  select id, slug into v_evento_teste, v_evento_slug from eventos where slug = 'teste2027';
  if v_evento_teste is null then
    raise exception 'Evento "teste2027" nao encontrado';
  end if;

  select id into v_id
  from notificacoes
  where tipo = 'contrato_assinado' and evento_id = v_evento_teste
    and destinatario = 'gerardocarvalhogp@gmail.com'
  order by created_at desc
  limit 1;

  if v_id is null then
    raise exception 'Notificacao de teste (contrato_assinado, redirecionada) nao encontrada';
  end if;

  select g.nome into v_nome
  from gestores g where g.nome = 'GERARDO CARVALHO';

  update notificacoes set corpo = format(
    E'Olá, %s.\n\nContrato assinado, obrigado. Agora complete seus dados de hospedagem — quem vai com você e se vai usar o transfer.\n\nhttps://ciocerrado.netlify.app/gestao/rooming.html?evento=%s\n\nEquipe CIO Cerrado',
    coalesce(v_nome, 'GERARDO CARVALHO'), v_evento_slug)
  where id = v_id;

  raise notice 'Notificacao % atualizada com o corpo (com link do rooming).', v_id;
end $$;
