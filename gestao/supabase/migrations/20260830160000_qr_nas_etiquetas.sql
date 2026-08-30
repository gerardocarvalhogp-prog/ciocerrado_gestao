-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — fase 3b: QR no cracha
--
-- v_etiquetas ganha pessoa_key, no mesmo formato ja usado por
-- v_esperados/checkin_registrar ("ocupante:<uuid>",
-- "participante:<uuid>", "usuario_patro:<uuid>") — o QR impresso no
-- cracha carrega esse texto puro, sem URL. A leitura acontece dentro
-- do checkin.html/admin.html ja autenticados; o QR sozinho, fora do
-- sistema, nao abre nem entrega nada.
-- =====================================================================

set search_path = gestao, public;

-- pessoa_key entra como 1a coluna, na frente de apto — CREATE OR
-- REPLACE VIEW so aceita coluna nova no final, precisa dropar antes.
-- O cascade leva admin_etiquetas junto; recriada logo abaixo.
drop view if exists v_etiquetas cascade;

create or replace view v_etiquetas as
  select r.evento_id,
         'ocupante:' || o.id::text as pessoa_key,
         q.numero as apto,
         o.nome,
         coalesce(p.empresa, g.empresa) as empresa,
         case
           when o.data_nascimento is not null and age(o.data_nascimento::timestamp) < interval '21 years' then 'S/CRACHA'
           else coalesce(o.categoria_cracha,
                case
                  when r.patrocinador_id is not null then 'PATROCINADOR'
                  when o.tipo = 'titular' then 'PROTAGONISTA'
                  else 'ACOMPANHANTE'
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
         'participante:' || pa.id::text,
         null, g.nome, g.empresa, 'PROTAGONISTA', 'inscricao'
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  where pa.status = 'aprovado'
    and not exists (select 1 from reservas r where r.participante_id = pa.id and r.status <> 'cancelado')

  union all
  select p.evento_id,
         'usuario_patro:' || u.id::text,
         null, coalesce(u.nome, split_part(u.email,'@',1)), p.empresa, 'PATROCINADOR', 'patrocinador'
  from usuarios_patrocinador u
  join patrocinadores p on p.id = u.patrocinador_id
  where u.ativo and p.status = 'ativo'
    and not exists (select 1 from reservas r where r.patrocinador_id = p.id and r.status <> 'cancelado');

-- CREATE OR REPLACE VIEW reseta security_invoker pro padrao (false) —
-- essa view so roda com a RLS de quem consulta por causa da correcao
-- de 24/08/2026 (20260824120000_fecha_views_para_anon.sql). Sem esta
-- linha, a troca acima reabriria o vazamento que aquela migration fechou.
alter view v_etiquetas set (security_invoker = true);

-- funcao plpgsql que so LE a view por dentro do corpo nao conta como
-- dependencia de catalogo — o cascade do drop view acima nao a pegou.
drop function if exists admin_etiquetas(text, text, text);

create or replace function admin_etiquetas(p_evento_slug text, p_categoria text default null, p_origem text default null)
returns table(pessoa_key text, apto text, nome text, empresa text, categoria text, origem text)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();
  return query
    select v.pessoa_key, v.apto, v.nome, v.empresa, v.categoria, v.origem
    from v_etiquetas v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where (p_categoria is null or v.categoria = p_categoria)
      and (p_origem is null or v.origem = p_origem)
    order by
      (v.apto is null),
      nullif(regexp_replace(coalesce(v.apto,''),'[^0-9]','','g'),'')::int nulls last,
      v.categoria, v.nome;
end;
$$;

revoke all on function admin_etiquetas(text,text,text) from public, anon;
grant all on function admin_etiquetas(text,text,text) to authenticated, service_role;
