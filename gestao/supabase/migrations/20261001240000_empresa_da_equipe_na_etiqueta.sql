-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Etiqueta de quem esta num quarto de equipe (STAFF, CIO Cerrado etc.)
-- saia com o campo EMPRESA em branco: v_etiquetas so sabia pegar
-- empresa de patrocinador (p.empresa) ou de gestor/CIO (g.empresa), e
-- reserva de equipe nao tem nenhum dos dois (patrocinador_id e
-- participante_id ficam null). Pedido do organizador em 01/10/2026.
--
-- O dado que falta ja existe: `reservas.rotulo` guarda o time ou
-- responsavel ("Coordenacao", "Seguranca", "CIO Cerrado"...), definido
-- em admin_salvar_quarto_equipe — e' exatamente o mesmo fallback que
-- admin_listar_alocacao ja usa pra essa mesma situacao desde
-- 20260831140000 (`coalesce(p.empresa, g.empresa, r.rotulo)`). So'
-- faltava v_etiquetas fazer igual.
--
-- So muda a PRIMEIRA parte do UNION (ocupante de quarto) — as outras
-- duas (participante sem reserva ainda, usuario de patrocinador) nunca
-- sao equipe, nao tem rotulo pra cair.
--
-- CREATE OR REPLACE VIEW reseta security_invoker pro padrao (achado em
-- 20260910090000) — reafirma na sequencia, mesmo padrao.
-- =====================================================================

set search_path = gestao, public;

create or replace view v_etiquetas as
select r.evento_id,
       'ocupante:' || o.id::text as pessoa_key,
       q.numero as apto,
       o.nome,
       coalesce(p.empresa, g.empresa, r.rotulo) as empresa,
       case
         when o.data_nascimento is not null
              and age(o.data_nascimento::timestamp) < interval '21 years'
           then 'S/CRACHA'
         else coalesce(o.categoria_cracha,
           case
             when r.patrocinador_id is not null then 'PATROCINADOR'
             when o.tipo = 'titular' then 'PROTAGONISTA'
             else 'FAMILIAR'
           end)
       end as categoria,
       'quarto' as origem
from ocupantes o
join reservas r on r.id = o.reserva_id and r.status <> 'cancelado'
left join quartos q on q.id = r.quarto_id
left join patrocinadores p on p.id = r.patrocinador_id
left join participantes pa on pa.id = r.participante_id
left join gestores g on g.id = pa.gestor_id
union all
select pa.evento_id,
       'participante:' || pa.id::text as pessoa_key,
       null as apto,
       g.nome,
       g.empresa,
       'PROTAGONISTA' as categoria,
       'inscricao' as origem
from participantes pa
join gestores g on g.id = pa.gestor_id
where pa.status = 'aprovado'
  and not exists (select 1 from reservas r
                  where r.participante_id = pa.id and r.status <> 'cancelado')
union all
select p.evento_id,
       'usuario_patro:' || u.id::text as pessoa_key,
       null as apto,
       coalesce(u.nome, split_part(u.email, '@', 1)),
       p.empresa,
       'PATROCINADOR' as categoria,
       'patrocinador' as origem
from usuarios_patrocinador u
join patrocinadores p on p.id = u.patrocinador_id
where u.ativo and p.status = 'ativo'
  and not exists (select 1 from reservas r
                  where r.patrocinador_id = p.id and r.status <> 'cancelado');

alter view v_etiquetas set (security_invoker = true);

-- ---------------------------------------------------------------------
-- autoconfere: security_invoker nao perdido, e a coluna empresa
-- realmente preenchida pra quem so tem rotulo (sem depender de ter
-- dado de teste de equipe no banco local pra validar isso)
-- ---------------------------------------------------------------------
do $$
declare
  v_invoker boolean;
  v_def text;
begin
  select coalesce((
    select (option_value = 'true')
    from pg_options_to_table(
      (select reloptions from pg_class
        where relname = 'v_etiquetas' and relnamespace = 'gestao'::regnamespace))
    where option_name = 'security_invoker'
  ), false) into v_invoker;
  if not v_invoker then
    raise exception 'v_etiquetas perdeu security_invoker=true — vazamento de dado pra anon';
  end if;

  -- confere a definicao de verdade da view (nao um teste isolado do
  -- coalesce): o rotulo da equipe precisa estar la como fallback
  select pg_get_viewdef('gestao.v_etiquetas'::regclass) into v_def;
  if v_def !~ 'r\.rotulo' then
    raise exception 'v_etiquetas nao ficou com o fallback pro rotulo da equipe';
  end if;

  raise notice 'v_etiquetas: security_invoker ok, fallback pro rotulo da equipe confirmado na definicao.';
end $$;
