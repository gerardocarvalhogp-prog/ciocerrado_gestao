-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Financeiro (admin) listava toda fatura nao-cancelada, inclusive as
-- de total zero — toda vez que _recalcular_fatura_participante/
-- _recalcular_fatura_patrocinador roda (o que acontece o tempo todo,
-- em qualquer alteracao de rooming/quarto/transfer) ela cria/atualiza
-- uma linha 'estimada' mesmo quando nao ha nada a cobrar, so pra
-- registrar que ja foi calculado. Isso enchia a tela com CIO/
-- patrocinador que nao deve nada. Achado real, reportado pelo Gerardo.
-- =====================================================================

set search_path = gestao, public;

create or replace function admin_listar_faturas(p_evento_slug text, p_status text DEFAULT NULL::text, p_limite integer DEFAULT 500, p_offset integer DEFAULT 0)
returns table (
  id uuid, tipo text, nome text, empresa text, email text, total numeric,
  status text, vencimento date, emitida_em timestamptz, paga_em timestamptz,
  forma_pagamento text, observacao text, itens text, total_geral bigint
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select f.id,
           case when f.participante_id is not null then 'participante'
                else 'patrocinador' end,
           coalesce(g.nome, p.empresa),
           coalesce(g.empresa, p.empresa),
           coalesce(g.email, (select u.email from usuarios_patrocinador u
                              where u.patrocinador_id = p.id and u.ativo
                              order by u.created_at limit 1)),
           f.total, f.status, f.vencimento,
           f.emitida_em, f.paga_em, f.forma_pagamento, f.observacao,
           coalesce((select string_agg(fi.descricao || ' ×' || fi.quantidade, ', '
                                       order by fi.descricao)
                     from fatura_itens fi where fi.fatura_id = f.id), '—'),
           count(*) over ()
    from faturas f
    join eventos e on e.id = f.evento_id and e.slug = p_evento_slug
    left join participantes pa on pa.id = f.participante_id
    left join gestores g on g.id = pa.gestor_id
    left join patrocinadores p on p.id = f.patrocinador_id
    where f.status <> 'cancelada'
      and f.total > 0
      and (p_status is null or f.status = p_status)
    order by (f.status = 'paga'), f.total desc
    limit p_limite offset p_offset;
end;
$$;
