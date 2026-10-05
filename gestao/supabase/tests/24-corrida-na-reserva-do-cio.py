"""Corrida de verdade em _garantir_reserva (20260918090000) · gestao CIO Cerrado

    python supabase/tests/24-corrida-na-reserva-do-cio.py

O que isto prova, e por que nao cabe num .sql:

  Duplo clique / retry de rede em "salvar hospedagem" chama
  part_salvar_rooming duas vezes AO MESMO TEMPO. Antes de 20260918090000
  as duas chamadas podiam criar uma reserva cada (find-or-create sem
  trava). A correcao trava a linha do participante (SELECT ... FOR
  UPDATE) antes de procurar a reserva, e um indice unico parcial segura o
  invariante por baixo.

  Um teste transacional (.sql) roda numa conexao so — nunca ha duas
  transacoes disputando. Aqui sao duas sessoes psql de verdade:

    A: begin; part_salvar_rooming(...); pg_sleep(6); commit;
    B: (assim que A esta no pg_sleep) begin; part_salvar_rooming(...); commit;

  Com a trava: B fica parada esperando A (o tempo medido DENTRO do banco
  so da chamada passa de 1s), e quando A
  commita, B ACHA a reserva que A criou e reaproveita — sem erro, uma
  reserva so. Sem a trava: B nao esperaria, criaria a segunda reserva e
  estouraria no indice unico (erro), ou, sem o indice, ficaria com duas.

GRAVA DE VERDADE (as duas sessoes precisam enxergar o participante, entao
o cenario e commitado), mas cria tudo com o prefixo cob24 e APAGA no fim,
mesmo se o teste falhar. Pode rodar contra banco com dado dentro.
"""
import subprocess
import sys
import threading
import time

CONTAINER = 'supabase_db_gestao-cio-cerrado'
EMAIL = 'corrida24@teste.invalido'
SEGURA = 6  # segundos que A segura a transacao aberta
CLAIMS = '{"email":"%s","role":"authenticated"}' % EMAIL


def psql(sql, parar_no_erro=True):
    args = ['docker', 'exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-d', 'postgres', '-At', '-q']
    if parar_no_erro:
        args += ['-v', 'ON_ERROR_STOP=1']
    r = subprocess.run(args, input=sql.encode(), capture_output=True)
    return r.returncode, r.stdout.decode('utf-8', 'replace').strip(), r.stderr.decode('utf-8', 'replace').strip()


CENARIO = """
set search_path = gestao, public;
begin;
insert into eventos (slug,nome,status,data_inicio,data_fim)
values ('cob24','Cobertura 24 (corrida)','aberto','2027-08-12','2027-08-16');
insert into gestores (nome,email,empresa,cargo) values ('CIO Corrida Cob24','%s','Emp Corrida','CIO');
insert into participantes (evento_id,gestor_id,status,origem,aprovado_em)
select e.id, g.id, 'aprovado','manual',now() from eventos e, gestores g
 where e.slug='cob24' and g.email='%s';
insert into contratos (participante_id,status,assinado_em)
select pa.id,'assinado',now() from participantes pa join eventos e on e.id=pa.evento_id where e.slug='cob24';
commit;
""" % (EMAIL, EMAIL)

LIMPEZA = """
set search_path = gestao, public;
begin;
delete from fatura_itens where fatura_id in (select f.id from faturas f join eventos e on e.id=f.evento_id where e.slug='cob24');
delete from faturas where evento_id in (select id from eventos where slug='cob24');
delete from ocupantes where reserva_id in (select r.id from reservas r join eventos e on e.id=r.evento_id where e.slug='cob24');
delete from reservas where evento_id in (select id from eventos where slug='cob24');
delete from notificacoes where evento_id in (select id from eventos where slug='cob24') or destinatario='%s';
delete from contratos where participante_id in (select pa.id from participantes pa join eventos e on e.id=pa.evento_id where e.slug='cob24');
delete from participantes where evento_id in (select id from eventos where slug='cob24');
delete from gestores where email='%s';
delete from eventos where slug='cob24';
commit;
""" % (EMAIL, EMAIL)


def sessao(nome, familiar, segurar, saida):
    sql = """
set search_path = gestao, public;
begin;
set role authenticated;
set request.jwt.claims = '%s';
select extract(epoch from clock_timestamp());
select part_salvar_rooming('cob24', '[{"nome":"%s"}]'::jsonb) is not null;
select extract(epoch from clock_timestamp());
select (part_meu_status('cob24') ->> 'reserva_id');
%s
select extract(epoch from clock_timestamp());
commit;
""" % (CLAIMS, familiar, 'select pg_sleep(%d);' % segurar if segurar else '')
    cod, out, err = psql(sql)
    linhas = out.splitlines()
    # tempo DENTRO do banco, so da chamada — sem o overhead do docker exec
    segundos = float(linhas[2]) - float(linhas[0]) if len(linhas) >= 3 else 0.0
    saida[nome] = {'cod': cod, 'out': linhas, 'err': err, 'segundos': segundos,
                   'inicio': float(linhas[0]) if linhas else 0.0,
                   'fim': float(linhas[2]) if len(linhas) > 2 else 0.0,
                   'commit': float(linhas[-1]) if len(linhas) > 4 else 0.0,
                   'reserva': linhas[3] if len(linhas) > 3 else '?'}
    if '-v' in sys.argv:
        print(nome, 'inicio', linhas[0] if linhas else '?', 'fim', linhas[2] if len(linhas) > 2 else '?', err)


def rodada(problemas):
    psql(LIMPEZA, parar_no_erro=False)  # sobra de uma rodada interrompida
    cod, _, err = psql(CENARIO)
    if cod:
        print('CENARIO NAO MONTOU:', err)
        sys.exit(1)
    try:
        saida = {}
        a = threading.Thread(target=sessao, args=('A', 'Familiar A', SEGURA, saida))
        b = threading.Thread(target=sessao, args=('B', 'Familiar B', 0, saida))
        a.start()
        # so dispara B quando A ja criou a reserva e esta parada no pg_sleep,
        # com a transacao (e a trava) aberta — a latencia do docker exec
        # varia e, sem isso, as duas podiam nem se sobrepor
        limite = time.monotonic() + 30
        while time.monotonic() < limite:
            _, ativo, _ = psql("select count(*) from pg_stat_activity "
                               "where state = 'active' and query like 'select pg_sleep(%d)%%';" % SEGURA)
            if ativo == '1':
                break
            time.sleep(0.2)
        else:
            problemas.append('sessao A nunca chegou no pg_sleep — nao deu pra montar a corrida')
        b.start()
        a.join()
        b.join()

        A, B = saida['A'], saida['B']
        print('-- sessao A: salva e segura a transacao 6s — deve PASSAR (tempo = so a chamada, medido no banco)')
        print('   codigo %d, %.1fs, reserva %s' % (A['cod'], A['segundos'], A['reserva']))
        if A['cod']:
            problemas.append('sessao A falhou: ' + A['err'])
        print('-- sessao B (duplo clique, com A ainda aberta): espera A e reaproveita a reserva, sem erro — deve PASSAR')
        print('   codigo %d, %.1fs, reserva %s' % (B['cod'], B['segundos'], B['reserva']))
        if B['cod']:
            problemas.append('sessao B falhou (sem a trava, estouraria no indice unico): ' + B['err'])
        if not A['cod'] and not B['cod']:
            if B['inicio'] >= A['commit']:
                # B so comecou depois do commit da A: nao houve corrida nesta
                # rodada (latencia do docker exec) — nao prova nada, repete
                return 'inconclusivo'
            print('   B comecou %.1fs antes do commit da A e terminou %.1fs depois dele'
                  % (A['commit'] - B['inicio'], B['fim'] - A['commit']))
            if B['fim'] < A['commit']:
                problemas.append('sessao B terminou ANTES do commit da A — nao esperou a trava FOR UPDATE')
            if A['reserva'] != B['reserva']:
                problemas.append('A e B devolveram reservas diferentes: %s x %s' % (A['reserva'], B['reserva']))

        _, n, _ = psql("""select count(*) from gestao.reservas r join gestao.eventos e on e.id=r.evento_id
                          where e.slug='cob24' and r.status <> 'cancelado' and r.origem <> 'extra';""")
        _, ocup, _ = psql("""select string_agg(o.nome, ',' order by o.nome) from gestao.ocupantes o
                             join gestao.reservas r on r.id=o.reserva_id join gestao.eventos e on e.id=r.evento_id
                             where e.slug='cob24';""")
        print('-- no fim: UMA reserva principal, com o que a ultima a salvar (B) gravou — deve PASSAR')
        print('   reservas principais: %s; ocupantes: %s' % (n, ocup))
        if n != '1':
            problemas.append('esperava 1 reserva principal, achei ' + n)
        if 'Familiar B' not in ocup or 'Familiar A' in ocup:
            problemas.append('ocupantes deviam ser os da B (ultima a salvar): ' + ocup)
    finally:
        cod, _, err = psql(LIMPEZA)
        _, sobra, _ = psql("select count(*) from gestao.eventos where slug='cob24';")
        print('-- limpeza: cenario apagado — %s' % ('ok' if not cod and sobra == '0' else 'FALHOU ' + err))
        if cod or sobra != '0':
            problemas.append('limpeza falhou: ' + err)

    return 'ok'


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    for tentativa in range(1, 4):
        problemas = []
        if rodada(problemas) != 'inconclusivo' or problemas:
            break
        print('-- rodada %d inconclusiva (B so comecou depois do commit da A); repetindo\n' % tentativa)
    else:
        problemas = ['tres rodadas sem conseguir sobrepor as duas sessoes']
    if problemas:
        print('\nPROBLEMAS:')
        print('\n'.join('  !! ' + p for p in problemas))
        sys.exit(1)
    print('\nTUDO BATEU')


if __name__ == '__main__':
    main()
