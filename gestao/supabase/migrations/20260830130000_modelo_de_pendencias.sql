-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- Modulo de acompanhamento, presenca e cobranca — parte 3/4
--
-- Duas tabelas novas:
--
-- etapas_config: catalogo fixo das etapas rastreaveis. "categoria"
-- so serve pra escolher o prazo padrao ao gerar prazos_evento — nao
-- tem outro uso.
--
-- prazos_evento: prazo configuravel por evento x etapa. Etapa sem
-- linha aqui (ou com ativo=false) nao aparece pra ninguem naquele
-- evento — e assim que jantar fica sem "hospedagem_preenchida", por
-- exemplo, sem precisar de campo nenhum espalhado pelas tabelas de
-- negocio.
--
-- fatura_paga e caso especial: o prazo conta do VENCIMENTO da fatura,
-- nao da abertura da etapa (nao faz sentido cobrar "atencao" contando
-- dias desde que a fatura foi criada se o vencimento e livre). Por
-- isso essa etapa fica com dias_atencao/dias_atrasado nulos aqui — a
-- view (parte 4) trata ela à parte.
-- =====================================================================

set search_path = gestao, public;

create table if not exists etapas_config (
  chave     text primary key,
  publico   text not null check (publico in ('participante','patrocinador')),
  categoria text not null check (categoria in ('aprovacao','contrato','rooming','indicacao','fatura')),
  rotulo    text not null,
  ordem     integer not null
);

insert into etapas_config (chave, publico, categoria, rotulo, ordem) values
  ('inscricao_aprovada',            'participante', 'aprovacao', 'Inscrição aprovada',          1),
  ('contrato_assinado',             'participante', 'contrato',  'Contrato assinado',            2),
  ('hospedagem_preenchida',         'participante', 'rooming',   'Hospedagem preenchida',        3),
  ('fatura_paga',                   'participante', 'fatura',    'Fatura adicional paga',        4),
  ('presenca_confirmada',           'participante', 'indicacao', 'Presença confirmada',          5),
  ('contrato_patrocinio_assinado',  'patrocinador', 'contrato',  'Contrato de patrocínio assinado', 1),
  ('indicacao_cio_feita',           'patrocinador', 'indicacao', 'Indicação de CIO feita',        2),
  ('quartos_preenchidos',           'patrocinador', 'rooming',   'Ocupantes dos quartos preenchidos', 3),
  ('convidados_mesa_escolhidos',    'patrocinador', 'indicacao', 'Convidados de mesa redonda escolhidos', 4),
  ('convidados_jantar_escolhidos',  'patrocinador', 'indicacao', 'Convidados de jantar escolhidos', 5),
  ('brindes_definidos',             'patrocinador', 'indicacao', 'Brindes definidos',             6)
on conflict (chave) do nothing;

create table if not exists prazos_evento (
  id             uuid primary key default gen_random_uuid(),
  evento_id      uuid not null references eventos(id) on delete cascade,
  etapa_chave    text not null references etapas_config(chave),
  dias_atencao   integer,
  dias_atrasado  integer,
  ativo          boolean not null default true,
  unique (evento_id, etapa_chave),
  check (dias_atencao is null or dias_atrasado is null or dias_atrasado >= dias_atencao)
);

alter table etapas_config enable row level security;
alter table prazos_evento enable row level security;
create policy etapas_config_staff_leitura on etapas_config for select using (is_staff());
create policy prazos_evento_staff_all on prazos_evento using (is_staff());

-- ---------------------------------------------------------------------
-- Gera os prazos padrao pra um evento — usado agora pra semear os
-- eventos que ja existem, e disponivel na tela pra qualquer evento
-- novo (o organizador ajusta depois, nao precisa acertar de primeira).
-- ---------------------------------------------------------------------
create or replace function admin_gerar_prazos_padrao(p_evento_slug text)
returns jsonb language plpgsql security definer
set search_path = gestao, public as $$
declare v_evento uuid; v_criados int;
begin
  perform _exige_admin();
  select id into v_evento from eventos where slug = p_evento_slug;
  if v_evento is null then
    raise exception 'Evento nao encontrado' using errcode = 'P0002';
  end if;

  insert into prazos_evento (evento_id, etapa_chave, dias_atencao, dias_atrasado)
  select v_evento, ec.chave,
    case ec.categoria
      when 'aprovacao' then 3
      when 'contrato'  then 5
      when 'rooming'   then 7
      when 'indicacao' then 7
      else null -- fatura: sem prazo generico, ver view de pendencias
    end,
    case ec.categoria
      when 'aprovacao' then 7
      when 'contrato'  then 10
      when 'rooming'   then 15
      when 'indicacao' then 15
      else null
    end
  from etapas_config ec
  where not exists (
    select 1 from prazos_evento pe
    where pe.evento_id = v_evento and pe.etapa_chave = ec.chave
  );

  get diagnostics v_criados = row_count;
  return jsonb_build_object('ok', true, 'criados', v_criados);
end;
$$;

revoke all on function admin_gerar_prazos_padrao(text) from public, anon;
grant all on function admin_gerar_prazos_padrao(text) to authenticated, service_role;

-- semeia os eventos que ja existem — insercao direta, nao via RPC:
-- admin_gerar_prazos_padrao exige _exige_admin(), que le auth.jwt() e
-- nao existe nesta sessao de migration (superuser, sem JWT nenhum).
insert into prazos_evento (evento_id, etapa_chave, dias_atencao, dias_atrasado)
select e.id, ec.chave,
  case ec.categoria
    when 'aprovacao' then 3
    when 'contrato'  then 5
    when 'rooming'   then 7
    when 'indicacao' then 7
    else null
  end,
  case ec.categoria
    when 'aprovacao' then 7
    when 'contrato'  then 10
    when 'rooming'   then 15
    when 'indicacao' then 15
    else null
  end
from eventos e
cross join etapas_config ec
on conflict (evento_id, etapa_chave) do nothing;
