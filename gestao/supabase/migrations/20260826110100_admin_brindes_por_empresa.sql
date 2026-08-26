-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- A lista de brindes da organizacao acompanha o modelo por empresa.
--
-- Depois de 20260826110000 o brinde deixou de ter quarto: a coluna
-- `quarto` da listagem passaria a vir nula em toda linha, e uma coluna
-- sempre vazia numa tabela e pior que coluna nenhuma — quem olha fica
-- procurando o dado que sumiu.
--
-- No lugar entram as duas coisas que a organizacao precisa saber para
-- se preparar: para ONDE vai (stand ou quarto) e QUANTOS quartos a
-- empresa tem, que e o tamanho do servico se for entrega porta a porta.
-- =====================================================================

set search_path = gestao, public;

drop function if exists admin_listar_brindes(text, text, int, int);

create function admin_listar_brindes(
  p_evento_slug text,
  p_status text default null,
  p_limite int default 500,
  p_offset int default 0
) returns table (
  brinde_id uuid,
  empresa text,
  cota text,
  destino text,
  quartos int,
  descricao text,
  quantidade int,
  status text,
  transportadora text,
  rastreio text,
  enviado_em timestamptz,
  recebido_em timestamptz,
  recebido_por text,
  entregue_em timestamptz,
  entregue_por text,
  observacao text
)
language plpgsql stable security definer
set search_path = gestao, public as $$
begin
  perform _exige_staff();

  return query
    select b.id, p.empresa, c.nome, b.destino,
           (select count(*)::int from reservas r
             where r.patrocinador_id = p.id and r.status <> 'cancelado'),
           b.descricao, b.quantidade, b.status,
           b.transportadora, b.rastreio,
           b.enviado_em, b.recebido_em, b.recebido_por,
           b.entregue_em, b.entregue_por, b.observacao
    from brindes b
    join patrocinadores p on p.id = b.patrocinador_id
    join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
    left join cotas c on c.id = p.cota_id
    where b.vai_enviar
      and (p_status is null or b.status = p_status)
    -- quem ainda nao chegou primeiro, e dentro disso quem vai para o
    -- quarto antes: essa e a fila que da trabalho na vespera
    order by case b.status
               when 'prometido' then 1 when 'enviado' then 2
               when 'recebido'  then 3 when 'entregue' then 4
               else 5 end,
             case b.destino when 'quarto' then 1 else 2 end,
             p.empresa
    limit greatest(coalesce(p_limite, 500), 1)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- O resumo ganha a quebra por destino: e o numero que diz se vai dar
-- trabalho de camareira ou nao.
create or replace function admin_brindes_resumo(p_evento_slug text)
returns jsonb language plpgsql stable security definer
set search_path = gestao, public as $$
declare v_out jsonb;
begin
  perform _exige_staff();

  select jsonb_build_object(
    'total',      count(*),
    'prometido',  count(*) filter (where b.status = 'prometido'),
    'enviado',    count(*) filter (where b.status = 'enviado'),
    'recebido',   count(*) filter (where b.status = 'recebido'),
    'entregue',   count(*) filter (where b.status = 'entregue'),
    'cancelado',  count(*) filter (where b.status = 'cancelado'),
    'no_stand',   count(*) filter (where b.destino = 'stand'),
    'no_quarto',  count(*) filter (where b.destino = 'quarto'),
    'empresas',   count(distinct b.patrocinador_id))
  into v_out
  from brindes b
  join patrocinadores p on p.id = b.patrocinador_id
  join eventos e on e.id = p.evento_id and e.slug = p_evento_slug
  where b.vai_enviar;

  return coalesce(v_out, jsonb_build_object('total', 0));
end;
$$;

revoke execute on function admin_listar_brindes(text, text, int, int) from public, anon;
grant execute on function admin_listar_brindes(text, text, int, int) to authenticated, service_role;
