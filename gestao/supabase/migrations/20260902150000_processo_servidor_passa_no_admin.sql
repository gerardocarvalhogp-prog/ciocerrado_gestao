-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- service_role passa em is_admin()/is_staff() — processo de servidor,
-- nao usuario.
--
-- integracao.py fala com o Supabase pela service_role (o proprio
-- cabecalho do arquivo ja documenta: "ignora RLS de proposito: e um
-- processo de servidor, nao um usuario"). Isso ja e verdade pra
-- leitura/escrita direta de tabela (service_role sempre bypassa RLS,
-- em qualquer projeto Supabase). Mas is_admin()/is_staff() nao sao RLS
-- — sao checagem imperativa dentro da funcao (auth.jwt()->>'email'
-- contra a tabela admins), e service_role nao tem e-mail de admin
-- nenhum. Toda funcao _exige_admin()/_exige_staff() recusava a
-- service_role, mesmo a service_role ja podendo fazer a mesma coisa
-- direto na tabela sem controle nenhum — a restricao nao protegia
-- nada, so empurrava quem tem essa chave a duplicar a logica de
-- negocio em Python em vez de reusar a funcao SQL que ja existe e ja
-- e testada (caso concreto: jantar_importar_convidados_sympla, pro
-- integracao.py sincronizar convidados de jantar pela API do Sympla).
-- =====================================================================

set search_path = gestao, public;

create or replace function is_admin()
returns boolean language sql stable security definer
set search_path to 'gestao', 'public' as $$
  select (auth.jwt() ->> 'role') = 'service_role'
     or exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and role = 'admin' and ativo
  );
$$;

create or replace function is_staff()
returns boolean language sql stable security definer
set search_path to 'gestao', 'public' as $$
  select (auth.jwt() ->> 'role') = 'service_role'
     or exists (
    select 1 from admins
    where email_norm = norm_doc(auth.jwt() ->> 'email')
      and ativo
  );
$$;
