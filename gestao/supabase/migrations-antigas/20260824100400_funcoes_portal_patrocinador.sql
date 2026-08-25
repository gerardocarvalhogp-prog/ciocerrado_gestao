-- =====================================================================
-- SISTEMA DE GESTAO CIO CERRADO
-- funcoes-patro.sql  ·  portal do patrocinador
--
-- Roda DEPOIS de schema.sql e schema-extra.sql.
--
-- Contrato: cada funcao aqui e chamada por portal.html. Os nomes de
-- parametro (p_*) e os nomes de coluna do retorno fazem parte do
-- contrato com a tela - mudar um exige mudar o outro.
--
-- Padrao: SECURITY DEFINER + checagem de papel na primeira linha. O
-- front e estatico, nao da para confiar nele.
-- =====================================================================

set search_path = gestao, public;

-- =====================================================================
-- 0. HELPERS
-- =====================================================================

-- Capacidade nominal do tipo. A reserva existe antes de ter quarto
-- fisico atribuido, entao nem sempre da para ler de quartos.capacidade.
create or replace function cap_tipo(p_tipo text)
returns int language sql immutable as $$
  select case p_tipo when 'single' then 1
                     when 'duplo'  then 2
                     when 'triplo' then 3
                     else 1 end;
$$;

create or replace function evento_id_por_slug(p_slug text)
returns uuid language sql stable security definer set search_path = gestao, public as $$
  select id from eventos where slug = p_slug;
$$;


-- =====================================================================
-- 1. PAINEL
-- =====================================================================


-- Dados do evento para a aba Manual. Nome, local, datas e prazos.
create or replace function patro_manual(p_evento_slug text)
returns table (
  nome text, local text, data_inicio date, data_fim date,
  prazo_contrato date, prazo_rooming date, prazo_cancelamento date
)
language sql stable security definer set search_path = gestao, public as $$
  select e.nome, e.local, e.data_inicio, e.data_fim,
         e.prazo_contrato, e.prazo_rooming, e.prazo_cancelamento
  from eventos e
  where e.slug = p_evento_slug;
$$;

-- Ordem das cotas. A tela monta o trilho da fila com isto em vez de ter
-- a ordem escrita no HTML - cota nova criada no painel aparece la sozinha.
create or replace function listar_cotas(p_evento_slug text)
returns table (nome text, ordem_prioridade int)
language sql stable security definer set search_path = gestao, public as $$
  select c.nome, c.ordem_prioridade
  from cotas c
  where c.evento_id = evento_id_por_slug(p_evento_slug)
  order by c.ordem_prioridade;
$$;

-- =====================================================================
-- 2. QUARTOS
-- =====================================================================

create or replace function patro_listar_quartos(p_patrocinador_id uuid)
returns table (
  reserva_id uuid,
  rotulo text,
  tipo text,
  capacidade int,
  ocupantes bigint,
  quarto_numero text,
  origem text,
  status text,
  usa_transfer boolean,
  transfer_origem text,
  brinde_vai_enviar boolean,
  brinde_descricao text
)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  if not pode_ver_patrocinador(p_patrocinador_id) then
    raise exception 'Sem acesso a este patrocinador.';
  end if;

  return query
  select
    r.id, r.rotulo, r.tipo,
    coalesce(q.capacidade, cap_tipo(r.tipo)),
    (select count(*) from ocupantes o where o.reserva_id = r.id),
    q.numero, r.origem, r.status, r.usa_transfer, r.transfer_origem,
    coalesce(b.vai_enviar,false), b.descricao
  from reservas r
  left join quartos q on q.id = r.quarto_id
  left join brindes b on b.reserva_id = r.id
  where r.patrocinador_id = p_patrocinador_id
    and r.status <> 'cancelado'
  order by r.origem, r.created_at;
end;
$$;

-- Disponibilidade real do hotel, por tipo. Alimenta o bloco "Quartos
-- disponiveis" - le a view, que ja desconta o que esta reservado.
create or replace function patro_disponibilidade(p_evento_slug text)
returns table (tipo text, livres bigint)
language sql stable security definer set search_path = gestao, public as $$
  select v.tipo, v.livres
  from v_disponibilidade_quartos v
  where v.evento_id = evento_id_por_slug(p_evento_slug)
    and v.livres > 0
  order by v.tipo;
$$;


-- Reserva de quarto alem da cota.
--
-- A corrida aqui e real: duas empresas clicam em "Reservar" no ultimo
-- quarto no mesmo segundo. FOR UPDATE SKIP LOCKED faz a segunda pegar
-- outro quarto livre em vez de esperar e falhar; se nao houver outro,
-- volta ok=false e a tela avisa, em vez de estourar erro.
create or replace function patro_comprar_quarto(p_patrocinador_id uuid, p_tipo text)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_quarto uuid;
  v_reserva uuid;
  v_rotulo text;
  v_n int;
begin
  if not pode_ver_patrocinador(p_patrocinador_id) then
    raise exception 'Sem acesso a este patrocinador.';
  end if;
  if p_tipo not in ('single','duplo','triplo') then
    raise exception 'Tipo de quarto invalido.';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;
  if v_evento is null then
    raise exception 'Patrocinador nao encontrado.';
  end if;

  select q.id into v_quarto
  from quartos q
  where q.evento_id = v_evento
    and q.tipo = p_tipo
    and q.status = 'disponivel'
    and not exists (select 1 from reservas r
                    where r.quarto_id = q.id and r.status <> 'cancelado')
  order by q.numero nulls last
  for update skip locked
  limit 1;

  if v_quarto is null then
    return jsonb_build_object('ok', false, 'motivo', 'esgotado');
  end if;

  select count(*)+1 into v_n from reservas
  where patrocinador_id = p_patrocinador_id and status <> 'cancelado';
  v_rotulo := 'Quarto ' || v_n;

  insert into reservas (evento_id, quarto_id, patrocinador_id, rotulo, tipo, origem, status)
  values (v_evento, v_quarto, p_patrocinador_id, v_rotulo, p_tipo, 'extra', 'rascunho')
  returning id into v_reserva;

  update quartos set status = 'reservado' where id = v_quarto;

  perform _recalcular_fatura_patrocinador(p_patrocinador_id);

  return jsonb_build_object('ok', true, 'reserva_id', v_reserva, 'rotulo', v_rotulo);
end;
$$;

-- So quarto EXTRA pode ser cancelado pelo portal. Quarto de cota nao -
-- ele faz parte do contrato, e sair dele e conversa com a organizacao.
create or replace function patro_cancelar_quarto_extra(p_reserva_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare r record;
begin
  select * into r from reservas where id = p_reserva_id for update;
  if r.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not pode_ver_patrocinador(r.patrocinador_id) then
    raise exception 'Sem acesso a esta reserva.';
  end if;
  if r.origem <> 'extra' then
    raise exception 'Somente quartos extras podem ser cancelados pelo portal.';
  end if;

  update reservas set status = 'cancelado', quarto_id = null where id = p_reserva_id;
  if r.quarto_id is not null then
    update quartos set status = 'disponivel' where id = r.quarto_id;
  end if;

  perform _recalcular_fatura_patrocinador(r.patrocinador_id);
  return jsonb_build_object('ok', true);
end;
$$;

-- Salva a lista completa de ocupantes do quarto de uma vez.
--
-- A tela sempre manda a lista inteira, entao aqui e substituicao, nao
-- merge: apaga e regrava. Check-in ja feito guarda nome e e-mail
-- proprios (checkins.ocupante_id e ON DELETE SET NULL), entao o
-- historico do evento nao se perde quando alguem corrige um nome.
create or replace function patro_salvar_quarto(
  p_reserva_id uuid,
  p_ocupantes jsonb,
  p_usa_transfer boolean default false,
  p_transfer_origem text default null,
  p_brinde_enviar boolean default false,
  p_brinde_descricao text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  r record;
  v_cap int;
  v_qtd int;
  v_status text;
begin
  select * into r from reservas where id = p_reserva_id for update;
  if r.id is null then raise exception 'Reserva nao encontrada.'; end if;
  if not pode_ver_patrocinador(r.patrocinador_id) then
    raise exception 'Sem acesso a esta reserva.';
  end if;
  if r.status = 'cancelado' then
    raise exception 'Esta reserva foi cancelada.';
  end if;
  if p_transfer_origem is not null and p_transfer_origem not in ('GYN','BSB') then
    raise exception 'Origem de transfer invalida.';
  end if;

  v_cap := coalesce((select capacidade from quartos where id = r.quarto_id),
                    cap_tipo(r.tipo));

  select count(*) into v_qtd
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) o
  where nullif(trim(coalesce(o->>'nome','')),'') is not null;

  if v_qtd = 0 then
    raise exception 'Informe pelo menos um ocupante.';
  end if;
  if v_qtd > v_cap then
    raise exception 'Este quarto comporta % pessoa(s); voce enviou %.', v_cap, v_qtd;
  end if;

  delete from ocupantes where reserva_id = p_reserva_id;

  insert into ocupantes (reserva_id, nome, cpf, tipo, usa_transfer, categoria_cracha)
  select p_reserva_id,
         trim(o->>'nome'),
         nullif(trim(coalesce(o->>'cpf','')),''),
         coalesce(nullif(o->>'tipo',''),'adulto'),
         coalesce((o->>'usa_transfer')::boolean, false),
         'PATROCINADOR'
  from jsonb_array_elements(coalesce(p_ocupantes,'[]'::jsonb)) o
  where nullif(trim(coalesce(o->>'nome','')),'') is not null;

  v_status := case when v_qtd >= v_cap then 'completo' else 'rascunho' end;

  update reservas
     set usa_transfer    = coalesce(p_usa_transfer,false),
         transfer_origem = p_transfer_origem,
         status          = v_status
   where id = p_reserva_id;

  -- brinde: uma linha por reserva
  if coalesce(p_brinde_enviar,false) or p_brinde_descricao is not null then
    if exists (select 1 from brindes where reserva_id = p_reserva_id) then
      update brindes
         set vai_enviar = coalesce(p_brinde_enviar,false),
             descricao  = p_brinde_descricao
       where reserva_id = p_reserva_id;
    else
      insert into brindes (patrocinador_id, reserva_id, vai_enviar, descricao)
      values (r.patrocinador_id, p_reserva_id,
              coalesce(p_brinde_enviar,false), p_brinde_descricao);
    end if;
  else
    delete from brindes where reserva_id = p_reserva_id;
  end if;

  -- carimba "fechou" quando nao sobra nenhum quarto em rascunho. E o que
  -- desempata a ordem de escolha da mesa redonda dentro da mesma cota.
  update patrocinadores p
     set fechado_em = now()
   where p.id = r.patrocinador_id
     and p.fechado_em is null
     and not exists (
       select 1 from reservas r2
       where r2.patrocinador_id = p.id
         and r2.status = 'rascunho');

  perform _recalcular_fatura_patrocinador(r.patrocinador_id);

  return jsonb_build_object('ok', true, 'status', v_status, 'ocupantes', v_qtd);
end;
$$;

-- =====================================================================
-- 3. MESA REDONDA / REUNIAO EXCLUSIVA
-- =====================================================================


-- Onde a empresa esta na fila desta sessao.
--
-- A ordem vem de v_ordem_escolha (cota mais alta primeiro; dentro da
-- cota, quem fechou contrato e rooming antes). "Minha vez" e quando
-- ninguem com prioridade maior ainda tem sessao aberta do mesmo tipo.
create or replace function patro_minha_vez(p_sessao_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = gestao, public as $$
declare
  s record;
  v_pos int;
  v_frente int;
  v_liberada boolean;
begin
  select * into s from sessoes where id = p_sessao_id;
  if s.id is null then raise exception 'Sessao nao encontrada.'; end if;
  if not pode_ver_patrocinador(s.patrocinador_id) then
    raise exception 'Sem acesso a esta sessao.';
  end if;

  select o.posicao into v_pos from v_ordem_escolha o
  where o.patrocinador_id = s.patrocinador_id;

  select count(*) into v_frente
  from sessoes s2
  join v_ordem_escolha o on o.patrocinador_id = s2.patrocinador_id
  where s2.evento_id = s.evento_id
    and s2.tipo = s.tipo
    and s2.escolha_encerrada_em is null
    and o.posicao < coalesce(v_pos, 999999);

  v_liberada := s.escolha_encerrada_em is null
                and v_frente = 0
                and (s.escolha_liberada_em is null or s.escolha_liberada_em <= now());

  return jsonb_build_object(
    'minha_vez', v_liberada,
    'posicao',   coalesce(v_pos, 0),
    'na_frente', v_frente
  );
end;
$$;

-- Convidados ainda livres para esta sessao.
--
-- Regra: quem ja foi escolhido por qualquer empresa some da lista de
-- todo mundo (dentro do mesmo tipo de sessao) - e o que a tela promete.
-- Ordem: primeiro quem a propria empresa indicou, depois porte
-- (faturamento), depois nome.
create or replace function patro_convidados_disponiveis(p_sessao_id uuid)
returns table (
  participante_id uuid,
  nome text,
  empresa text,
  cargo text,
  indicado_por_mim boolean
)
language plpgsql stable security definer set search_path = gestao, public as $$
declare s record;
begin
  select * into s from sessoes where id = p_sessao_id;
  if s.id is null then raise exception 'Sessao nao encontrada.'; end if;
  if not pode_ver_patrocinador(s.patrocinador_id) then
    raise exception 'Sem acesso a esta sessao.';
  end if;

  return query
  select
    pa.id, g.nome, g.empresa, g.cargo,
    -- coalesce e obrigatorio: indicado_por_patrocinador_id e nulo para
    -- quem ninguem indicou, e "null = uuid" da NULL, nao false.
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false)
      as indicado_por_mim
  from participantes pa
  join gestores g on g.id = pa.gestor_id
  left join participante_perfil pp on pp.participante_id = pa.id
  where pa.evento_id = s.evento_id
    and pa.status = 'aprovado'
    and not exists (
      select 1 from sessao_convidados sc
      join sessoes s2 on s2.id = sc.sessao_id
      where sc.participante_id = pa.id
        and sc.status = 'confirmado'
        and s2.evento_id = s.evento_id
        and s2.tipo = s.tipo
    )
  order by
    -- Sem o coalesce, "desc" traz NULL primeiro (a ordem do Postgres e
    -- NULL, true, false) e os NAO indicados subiriam acima dos
    -- indicados - invertendo a primeira camada da regra de alocacao.
    coalesce(pa.indicado_por_patrocinador_id = s.patrocinador_id, false) desc,
    pp.faturamento desc nulls last,
    g.nome;
end;
$$;

-- Confirma as escolhas da empresa nesta sessao.
--
-- Trava a sessao (FOR UPDATE) antes de contar vaga: duas abas do mesmo
-- patrocinador, ou a organizacao mexendo ao mesmo tempo, senao estouram
-- o limite. A checagem de vaga e feita aqui, nao na tela.
create or replace function patro_escolher_convidados(
  p_sessao_id uuid,
  p_participantes uuid[]
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  s record;
  v_ocupadas int;
  v_livres int;
  v_pedidos int;
  v_ins int := 0;
  v_vez jsonb;
begin
  select * into s from sessoes where id = p_sessao_id for update;
  if s.id is null then raise exception 'Sessao nao encontrada.'; end if;
  if not pode_ver_patrocinador(s.patrocinador_id) then
    raise exception 'Sem acesso a esta sessao.';
  end if;
  if s.escolha_encerrada_em is not null then
    raise exception 'A escolha desta sessao ja foi encerrada.';
  end if;

  v_vez := patro_minha_vez(p_sessao_id);
  if not (v_vez->>'minha_vez')::boolean then
    raise exception 'Ainda nao e a sua vez de escolher nesta sessao.';
  end if;

  v_pedidos := coalesce(array_length(p_participantes,1),0);
  if v_pedidos = 0 then
    raise exception 'Selecione pelo menos um convidado.';
  end if;

  select count(*) into v_ocupadas from sessao_convidados
  where sessao_id = p_sessao_id and status = 'confirmado';
  v_livres := s.vagas - v_ocupadas;

  if v_pedidos > v_livres then
    raise exception 'Restam % vaga(s) nesta sessao; voce escolheu %.', v_livres, v_pedidos;
  end if;

  -- alguem pode ter levado o convidado entre a tela carregar e o clique:
  -- o insert ignora quem ja foi tomado e o retorno diz quantos entraram
  insert into sessao_convidados (sessao_id, participante_id, origem, status)
  select p_sessao_id, x.pid, 'patrocinador', 'confirmado'
  from unnest(p_participantes) as x(pid)
  where exists (select 1 from participantes pa
                where pa.id = x.pid
                  and pa.evento_id = s.evento_id
                  and pa.status = 'aprovado')
    and not exists (
      select 1 from sessao_convidados sc
      join sessoes s2 on s2.id = sc.sessao_id
      where sc.participante_id = x.pid
        and sc.status = 'confirmado'
        and s2.evento_id = s.evento_id
        and s2.tipo = s.tipo
    )
  on conflict do nothing;

  get diagnostics v_ins = row_count;

  -- encerra sozinha quando a ultima vaga e preenchida: a proxima
  -- empresa da fila passa a ver "sua vez" sem ninguem fazer nada
  select count(*) into v_ocupadas from sessao_convidados
  where sessao_id = p_sessao_id and status = 'confirmado';

  if v_ocupadas >= s.vagas then
    update sessoes set escolha_encerrada_em = now() where id = p_sessao_id;
  end if;

  return jsonb_build_object('ok', true, 'inseridos', v_ins,
                            'pedidos', v_pedidos, 'ocupadas', v_ocupadas);
end;
$$;

-- Abre mao das vagas restantes e libera a fila.
create or replace function patro_passar_a_vez(p_sessao_id uuid)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare s record;
begin
  select * into s from sessoes where id = p_sessao_id for update;
  if s.id is null then raise exception 'Sessao nao encontrada.'; end if;
  if not pode_ver_patrocinador(s.patrocinador_id) then
    raise exception 'Sem acesso a esta sessao.';
  end if;
  if s.escolha_encerrada_em is not null then
    raise exception 'A escolha desta sessao ja foi encerrada.';
  end if;

  update sessoes
     set passou_em = now(), escolha_encerrada_em = now()
   where id = p_sessao_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- =====================================================================
-- 4. INDICACOES
-- =====================================================================

-- Indicacao NUNCA cria gestor nem participante. Ela sinaliza; quem
-- converte em cadastro e a organizacao (admin_converter_indicacao).
-- ja_na_base so muda o texto que a tela mostra.
create or replace function patro_indicar_cio(
  p_patrocinador_id uuid,
  p_nome text,
  p_empresa text default null,
  p_cargo text default null,
  p_email text default null,
  p_telefone text default null,
  p_observacao text default null
)
returns jsonb
language plpgsql security definer set search_path = gestao, public as $$
declare
  v_evento uuid;
  v_gestor uuid;
  v_id uuid;
begin
  if not pode_ver_patrocinador(p_patrocinador_id) then
    raise exception 'Sem acesso a este patrocinador.';
  end if;
  if nullif(trim(coalesce(p_nome,'')),'') is null then
    raise exception 'Informe o nome do CIO.';
  end if;

  select evento_id into v_evento from patrocinadores where id = p_patrocinador_id;

  if p_email is not null then
    select id into v_gestor from gestores where email_norm = norm_doc(p_email);
  end if;

  insert into indicacoes (evento_id, patrocinador_id, nome, empresa, cargo,
                          email, telefone, observacao, status, gestor_id)
  values (v_evento, p_patrocinador_id, trim(p_nome), p_empresa, p_cargo,
          p_email, p_telefone, p_observacao,
          case when v_gestor is not null then 'duplicado' else 'nova' end,
          v_gestor)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id,
                            'ja_na_base', v_gestor is not null);
end;
$$;

create or replace function patro_listar_indicacoes(p_patrocinador_id uuid)
returns table (id uuid, nome text, empresa text, cargo text,
               status text, created_at timestamptz)
language plpgsql stable security definer set search_path = gestao, public as $$
begin
  if not pode_ver_patrocinador(p_patrocinador_id) then
    raise exception 'Sem acesso a este patrocinador.';
  end if;

  return query
  select i.id, i.nome, i.empresa, i.cargo, i.status, i.created_at
  from indicacoes i
  where i.patrocinador_id = p_patrocinador_id
  order by i.created_at desc;
end;
$$;

-- =====================================================================
-- 5. PERMISSOES
-- O schema base deu execute para anon junto com authenticated. Nada
-- aqui pode rodar deslogado: sem JWT, meus_patrocinadores() volta vazio
-- e a funcao ja negaria - mas e melhor nao deixar a superficie exposta.
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'gestao'
      and p.proname like 'patro%'
  loop
    execute format('revoke execute on function %s from anon', f.sig);
  end loop;
end $$;
