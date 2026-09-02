-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Cobrança não sai mais pra quem já resolveu; lista mostra quem já foi
-- cobrado.
--
-- O BURACO
--
-- admin_disparar_cobranca so checa "esta pendente?" no momento de
-- ENFILEIRAR. O envio de verdade e outro passo, manual ("Enviar toda a
-- fila", aba Equipe) — pode ser minutos ou dias depois. Se a pessoa
-- resolver a pendencia nesse meio-tempo, o e-mail sai do mesmo jeito:
-- "voce esta atrasado em X" pra quem ja nao esta. E o achado do
-- usuario — "quem ta em dia nao tem que ter e-mail de cobranca".
--
-- O CONSERTO
--
-- `notificacoes` ganha `sujeito_id`, gravado por admin_disparar_cobranca
-- no momento de enfileirar. notificacoes_pendentes, que roda bem antes
-- do e-mail sair de verdade, confere de novo: se a pendencia daquele
-- sujeito+etapa nao existe mais em v_pendencias com status pendente,
-- marca a notificacao como pulada (sem chamar o Resend) e ela NAO
-- entra no lote devolvido pra function de envio.
--
-- DE BRINDE: "STATUS DIFERENTE PRA QUEM JA ENVIOU COBRANCA"
--
-- Mesma coluna sujeito_id resolve os dois pedidos juntos:
-- admin_pendencias_lista ganha `ultima_cobranca_em`, pra tela mostrar
-- quem ja foi cobrado sem precisar abrir cada linha pra descobrir.
-- =====================================================================

set search_path = gestao, public;

alter table notificacoes add column if not exists sujeito_id uuid;
comment on column notificacoes.sujeito_id is
  'So preenchido pra cobranca (tipo cobranca_*) — quem a etapa e sobre, pra notificacoes_pendentes conferir de novo antes de enviar que a pendencia ainda existe.';

-- ---------------------------------------------------------------------
-- 1. GRAVA O SUJEITO AO ENFILEIRAR
-- ---------------------------------------------------------------------
create or replace function admin_disparar_cobranca(p_sujeito_id uuid, p_etapa_chave text, p_assunto text, p_corpo text, p_forcar boolean DEFAULT false)
returns jsonb language plpgsql security definer
set search_path to 'gestao', 'public' as $$
declare
  v_row record;
  v_destinatarios text[];
  v_dest text;
  v_bloqueados int := 0;
  v_enviados int := 0;
  v_evento uuid;
begin
  perform _exige_admin();

  select * into v_row from v_pendencias
   where sujeito_id = p_sujeito_id and etapa_chave = p_etapa_chave
   limit 1;
  if v_row is null then
    raise exception 'Pendência não encontrada' using errcode = 'P0002';
  end if;
  if v_row.status = 'concluida' then
    raise exception 'Essa etapa já foi concluída — não há pendência para cobrar'
      using errcode = '55000';
  end if;
  v_evento := v_row.evento_id;

  if v_row.publico = 'participante' then
    v_destinatarios := array[v_row.destinatario_email];
  else
    select array_agg(up.email) into v_destinatarios
    from usuarios_patrocinador up
    where up.patrocinador_id = p_sujeito_id and up.ativo;
  end if;

  foreach v_dest in array coalesce(v_destinatarios, array[]::text[]) loop
    if not p_forcar and exists (
      select 1 from notificacoes n
      where n.tipo = 'cobranca_' || p_etapa_chave
        and n.destinatario = v_dest
        and n.created_at > now() - interval '3 days'
    ) then
      v_bloqueados := v_bloqueados + 1;
      continue;
    end if;

    insert into notificacoes (evento_id, destinatario, tipo, assunto, corpo, sujeito_id)
    values (v_evento, v_dest, 'cobranca_' || p_etapa_chave, p_assunto, p_corpo, p_sujeito_id);
    v_enviados := v_enviados + 1;
  end loop;

  insert into auditoria (tabela, registro_id, acao, campo, valor_novo, usuario)
  values ('v_pendencias', p_sujeito_id, 'cobranca_enfileirada', p_etapa_chave,
          v_enviados || ' enfileirada(s), ' || v_bloqueados || ' bloqueada(s) por reenvio recente',
          auth.jwt() ->> 'email');

  return jsonb_build_object('ok', true, 'enfileiradas', v_enviados, 'bloqueadas', v_bloqueados);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. NAO ENVIA COBRANCA CUJA PENDENCIA JA SUMIU
--
-- Confere de novo, bem antes do Resend ser chamado. Achar que a
-- pendencia sumiu marca a notificacao como enviada (pra sair da fila
-- sem tentar de novo) com um erro descritivo, em vez de mandar o
-- e-mail — e NAO entra no lote devolvido.
-- ---------------------------------------------------------------------
create or replace function notificacoes_pendentes(p_limite integer DEFAULT 50, p_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT 'email'::text)
returns table (id uuid, destinatario text, assunto text, corpo text, tipo text, canal text, template_nome text, template_params jsonb)
language plpgsql security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff();

  -- pula (sem chamar Resend) a cobranca cuja pendencia ja nao existe
  -- mais em aberto pro mesmo sujeito+etapa — resolvida entre o
  -- "preparar" e o envio de verdade, que roda em momento separado
  update notificacoes n set
    status = 'enviada',
    erro = 'Pulado: pendência já resolvida antes do envio',
    enviada_em = now()
  where n.status = 'enfileirada'
    and n.tipo like 'cobranca_%'
    and n.sujeito_id is not null
    and (p_id is null or n.id = p_id)
    and not exists (
      select 1 from v_pendencias vp
      where vp.sujeito_id = n.sujeito_id
        and vp.etapa_chave = substring(n.tipo from 10)
        and vp.status = 'pendente'
    );

  return query
    select n.id, n.destinatario, n.assunto, n.corpo, n.tipo,
           n.canal, n.template_nome, n.template_params
    from notificacoes n
    where n.status = 'enfileirada'
      and n.canal = coalesce(p_canal, 'email')
      and coalesce(trim(n.destinatario),'') <> ''
      and (p_id is null or n.id = p_id)
      and (p_id is not null or n.tentativas < 3)
    order by n.created_at
    limit case when p_id is not null then 1 else p_limite end;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. LISTA MOSTRA QUANDO FOI A ULTIMA COBRANCA (OU NUNCA)
-- ---------------------------------------------------------------------
drop function if exists admin_pendencias_lista(text, text, text, text, integer, integer);

create or replace function admin_pendencias_lista(p_evento_slug text, p_etapa_chave text DEFAULT NULL::text, p_nivel text DEFAULT NULL::text, p_publico text DEFAULT NULL::text, p_limite integer DEFAULT 200, p_offset integer DEFAULT 0)
returns table (
  sujeito_id uuid, sujeito_nome text, sujeito_empresa text, publico text,
  etapa_chave text, etapa_rotulo text, status text,
  aberta_em timestamptz, concluida_em timestamptz, dias_em_aberto integer,
  nivel text, destinatario_email text, ultima_cobranca_em timestamptz,
  total_geral bigint
)
language plpgsql stable security definer
set search_path to 'gestao', 'public' as $$
begin
  perform _exige_staff_do_evento_slug(p_evento_slug);
  return query
    select v.sujeito_id, v.sujeito_nome, v.sujeito_empresa, v.publico,
           v.etapa_chave, v.etapa_rotulo, v.status, v.aberta_em, v.concluida_em,
           v.dias_em_aberto, v.nivel, v.destinatario_email,
           (select max(n.created_at) from notificacoes n
             where n.sujeito_id = v.sujeito_id
               and n.tipo = 'cobranca_' || v.etapa_chave
               and n.erro is null),
           count(*) over ()
    from v_pendencias v
    join eventos e on e.id = v.evento_id and e.slug = p_evento_slug
    where v.status = 'pendente'
      and (p_etapa_chave is null or v.etapa_chave = p_etapa_chave)
      and (p_nivel is null or v.nivel = p_nivel)
      and (p_publico is null or v.publico = p_publico)
    order by case v.nivel when 'atrasado' then 0 when 'atencao' then 1 else 2 end,
             v.dias_em_aberto desc nulls last
    limit greatest(coalesce(p_limite,200),1) offset greatest(coalesce(p_offset,0),0);
end;
$$;

revoke execute on function admin_pendencias_lista(text,text,text,text,integer,integer) from public, anon;
grant execute on function admin_pendencias_lista(text,text,text,text,integer,integer) to authenticated, service_role;
