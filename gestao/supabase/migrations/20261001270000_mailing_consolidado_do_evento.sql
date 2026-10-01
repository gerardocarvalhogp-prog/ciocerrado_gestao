-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- admin_mailing_sessao so' exporta uma sessao por vez — pra mandar o
-- mailing de todo mundo era preciso abrir sessao por sessao e exportar
-- um Excel por vez. Pedido do organizador em 01/10/2026: "criar em um
-- unico relatorio todos os mailing... um patrocinador por pagina".
--
-- admin_mailing_evento junta tudo (todas as sessoes do evento) numa
-- unica consulta; quem agrupa "por pagina" (uma aba do Excel por
-- patrocinador) e' o JS, no proximo commit. Mesma mascara de e-mail
-- interno e mesmo coalesce(rotulo, perfil) que admin_mailing_sessao ja
-- usa, pra nao ter duas regras diferentes do que sai no mailing.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_mailing_evento(p_evento_slug text)
returns table(patrocinador text, tipo text, nome text, cargo text, empresa text, email text, telefone text, rotulo text)
language plpgsql
stable security definer
set search_path to 'gestao', 'public'
as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select p.empresa, s.tipo, g.nome, g.cargo, g.empresa,
           case when g.email like '%@interno.ciocerrado.com.br' then null
                else g.email end,
           g.telefone,
           coalesce(sc.rotulo, g.perfil)
    from sessao_convidados sc
    join sessoes s on s.id = sc.sessao_id
    join patrocinadores p on p.id = s.patrocinador_id
    join eventos e on e.id = s.evento_id and e.slug = p_evento_slug
    join participantes pa on pa.id = sc.participante_id
    join gestores g on g.id = pa.gestor_id
    where sc.status = 'confirmado'
    order by p.empresa, s.tipo, g.nome;
end;
$$;

revoke execute on function admin_mailing_evento(text) from public, anon;
grant execute on function admin_mailing_evento(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- autoconfere: funcao existe, confere a exigencia de staff, e traz a
-- mesma mascara de e-mail interno que admin_mailing_sessao
-- ---------------------------------------------------------------------
do $$
declare v_src text;
begin
  select pg_get_functiondef('gestao.admin_mailing_evento(text)'::regprocedure) into v_src;
  if v_src !~ '_exige_staff_do_evento_slug' then
    raise exception 'admin_mailing_evento nao confere acesso de staff';
  end if;
  if v_src !~ '@interno\.ciocerrado\.com\.br' then
    raise exception 'admin_mailing_evento nao mascara o e-mail interno';
  end if;
  raise notice 'admin_mailing_evento: ok.';
end $$;
