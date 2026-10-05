-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- gerardocarvalhogp@gmail.com fica vinculado SOMENTE ao patrocinador
-- SAP do evento "Teste da Ferramenta 2027" — pedido do organizador em
-- 29/09/2026, pra logar no portal.html e ver so' esse patrocinador
-- especifico de teste, sem nenhum outro vinculo (de teste anterior ou
-- de qualquer outra empresa) poluindo a sessao.
--
-- usuarios_patrocinador.empresa_id e' global (migration
-- 20260909100000) — um e-mail pode estar vinculado a varias empresas
-- ao mesmo tempo, e meus_patrocinadores() devolve TODAS. "Somente"
-- exige remover qualquer outro vinculo desse e-mail antes de garantir
-- o vinculo com a SAP, nao so' adicionar.
--
-- Mesmo padrao de dado-via-migration ja usado nas duas seeds
-- anteriores (INSERT/DELETE direto, superusuario, sem SET ROLE).
-- =====================================================================

set search_path = gestao, public;

do $$
declare v_empresa_id uuid; v_removidos int;
begin
  select id into v_empresa_id from empresas where lower(trim(nome)) = lower('SAP');
  if v_empresa_id is null then
    -- 05/10/2026: num banco que nao tem esse dado (db reset do zero, ambiente
    -- de teste) pula em vez de abortar o historico inteiro. No hospedado
    -- esta migration ja rodou; isto nao muda nada la.
    raise notice 'Empresa "SAP" nao encontrada no cadastro — confira o nome exato em admin.html (Patrocinadores) antes de rodar isto — pulando: este banco nao tem o dado que esta migration corrige';
    return;
  end if;

  delete from usuarios_patrocinador
   where email_norm = norm_doc('gerardocarvalhogp@gmail.com')
     and empresa_id <> v_empresa_id;
  get diagnostics v_removidos = row_count;

  insert into usuarios_patrocinador (empresa_id, email, nome, ativo)
  values (v_empresa_id, 'gerardocarvalhogp@gmail.com', 'Gerardo Carvalho', true)
  on conflict (empresa_id, email_norm) do update set ativo = true;

  raise notice 'gerardocarvalhogp@gmail.com vinculado so a SAP — % outro(s) vinculo(s) removido(s).', v_removidos;
end $$;
