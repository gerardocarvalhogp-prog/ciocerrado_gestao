-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Vincula gerardocarvalhogp@gmail.com a um patrocinador da cota
-- Esmeralda no evento de TESTE "Teste da Ferramenta 2027" — pedido do
-- organizador em 30/09/2026, pra testar a experiencia dessa cota no
-- portal (ate aqui o vinculo de teste era so com a SAP, migration
-- 20260929200000).
--
-- Mesmo padrao "somente este patrocinador" da migration anterior:
-- remove qualquer outro vinculo desse e-mail (inclusive o da SAP)
-- antes de garantir este, pra sessao nao ficar poluida com mais de
-- um patrocinador ao mesmo tempo.
--
-- A cota "Esmeralda" e a empresa de teste sao criadas se ainda nao
-- existirem neste evento — nao mexe em nada do evento real nem em
-- nenhum outro patrocinador ja cadastrado.
-- =====================================================================

set search_path = gestao, public;

do $$
declare
  v_evento_id  uuid;
  v_cota_id    uuid;
  v_empresa_id uuid;
  v_removidos  int;
begin
  select id into v_evento_id from eventos where nome = 'Teste da Ferramenta 2027';
  if v_evento_id is null then
    raise exception 'Evento "Teste da Ferramenta 2027" nao encontrado (busca por nome exato)';
  end if;

  select id into v_cota_id from cotas
   where evento_id = v_evento_id and lower(nome) = lower('Esmeralda');
  if v_cota_id is null then
    insert into cotas (evento_id, nome, ordem_prioridade, quartos_incluidos,
                        vagas_mesa_redonda, tem_reuniao_exclusiva, tem_jantar)
    values (v_evento_id, 'Esmeralda', 1, 2, 4, true, true)
    returning id into v_cota_id;
  end if;

  select id into v_empresa_id from empresas where lower(trim(nome)) = lower('Esmeralda Teste Ltda');
  if v_empresa_id is null then
    insert into empresas (nome, segmento)
    values ('Esmeralda Teste Ltda', 'Tecnologia')
    returning id into v_empresa_id;
  end if;

  insert into patrocinadores (evento_id, empresa_id, cota_id, empresa, status)
  values (v_evento_id, v_empresa_id, v_cota_id, 'Esmeralda Teste Ltda', 'ativo')
  on conflict (evento_id, empresa_id) do update set
    cota_id = excluded.cota_id,
    status  = 'ativo';

  delete from usuarios_patrocinador
   where email_norm = norm_doc('gerardocarvalhogp@gmail.com')
     and empresa_id <> v_empresa_id;
  get diagnostics v_removidos = row_count;

  insert into usuarios_patrocinador (empresa_id, email, nome, ativo)
  values (v_empresa_id, 'gerardocarvalhogp@gmail.com', 'Gerardo Carvalho', true)
  on conflict (empresa_id, email_norm) do update set ativo = true;

  raise notice 'gerardocarvalhogp@gmail.com vinculado so ao patrocinador "Esmeralda Teste Ltda" (cota Esmeralda) do evento de teste — % outro(s) vinculo(s) removido(s) (inclusive SAP, se estava ligado).', v_removidos;
end $$;
