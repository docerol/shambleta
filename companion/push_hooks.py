#!/usr/bin/env python3
"""M-4 (2026-10-07): a FILA de web push saiu de `class Store` para cá — fatia do
gate anti-god-node no regime da saída registrada ("fatiar é a saída"): zero
mudança de comportamento, cada SQL, cada docstring e cada comentário abaixo são
os mesmos de antes do corte, palavra por palavra; o que mudou é a casa. `Store`
herda `PushQueue`, então `store.push_*` continua a superfície testada por
`test_push.py` (W5+W6) e pelo harness Godot `web_delivery_test.gd`.

Referências cruzadas ao módulo `server` (o sender ativo, o tipo
`PushSubscriptionGone` e o resolvedor do calendário LiveOps) correm por
`_server()`, resolvidas na chamada: em tempo de import não há ciclo — este
arquivo não importa `server` no topo, e `server` importa este antes de
`class Store`.
"""
import json
import time


def _server():
    import server
    return server


class PushQueue:
    # ---- SOM-IDLE W5: web push (migration 052) ----------------------------
    # Registro/dedupe/fila aqui, sender plugável lá em cima. Toda função assume
    # as tabelas existentes: banco sem a migration 052 levanta sqlite3.Error e
    # o chamador (CLI/HTTP) traduz em erro explícito — nada de DDL escondido no
    # companion (a fonte do schema é única: data/conf/migrations/).

    PUSH_DEFAULT_TITLE = "Shambleta"
    PUSH_DEFAULT_BODY = "Sua colheita continua te esperando."

    def push_register(self, con, account_id, endpoint, p256dh, auth, now=None):
        """Upsert da subscription (uma por conta). A conta precisa existir no
        banco do jogo — registration de conta fantasma é lixo na fila. Retorna
        True se gravou, False se a conta não existe."""
        if self.account_id(con, account_id) is None:
            return False
        if now is None:
            now = int(time.time())
        con.execute(
            "INSERT INTO push_subscription (account_id, endpoint, p256dh, auth, "
            "updated_at) VALUES (?, ?, ?, ?, ?) "
            "ON CONFLICT(account_id) DO UPDATE SET endpoint = excluded.endpoint, "
            "p256dh = excluded.p256dh, auth = excluded.auth, "
            "updated_at = excluded.updated_at;",
            (int(account_id), str(endpoint), str(p256dh), str(auth), now))
        con.commit()
        return True

    def push_enqueue(self, con, account_id, title=None, body=None, now=None):
        """Enfileira uma notificação (status pending). Não envia nada."""
        if not account_id:
            raise ValueError("push_enqueue: account_id required")
        if now is None:
            now = int(time.time())
        cur = con.execute(
            "INSERT INTO push_outbox (account_id, title, body, status, created_at) "
            "VALUES (?, ?, ?, 'pending', ?);",
            (int(account_id),
             title or self.PUSH_DEFAULT_TITLE,
             body or self.PUSH_DEFAULT_BODY, now))
        con.commit()
        return cur.lastrowid

    def push_subscribed_count(self, con):
        return con.execute(
            "SELECT COUNT(*) FROM push_subscription;").fetchone()[0]

    def push_sweep(self, con, offline_seconds=86400, quiet_seconds=3 * 86400,
                   title=None, body=None, now=None):
        """Job único de varredura: contas COM subscription, offline há mais de
        `offline_seconds` (last_timestamp velho — 0/null nunca notifica), e sem
        QUALQUER linha na janela de silêncio `quiet_seconds`. Só enfileira;
        nunca envia inline. Retorna quantas linhas novas entraram na fila."""
        if now is None:
            now = int(time.time())
        rows = con.execute(
            "SELECT s.account_id FROM push_subscription s "
            "JOIN account a ON a.account_id = s.account_id "
            "WHERE a.last_timestamp > 0 "
            "AND a.last_timestamp < ? "
            "AND NOT EXISTS (SELECT 1 FROM push_outbox o "
            "                WHERE o.account_id = s.account_id "
            "                AND o.created_at > ?);",
            (now - int(offline_seconds), now - int(quiet_seconds))).fetchall()
        for (acct,) in rows:
            self.push_enqueue(con, acct, title=title, body=body, now=now)
        return len(rows)

    def push_season_close(self, con, lead_seconds=24 * 3600, now=None):
        """C-9 (2026-10-06): o segundo gancho do jogo — 'temporada fechando'.
        Uma temporada `active` que termina dentro de `lead_seconds` notifica
        TODO assinante UMA única vez por temporada: a chave de dedupe mora no
        corpo da própria fila (`season:<id>`), não em memória — restart não
        reabre a notificação, e spam de "fecha em breve" a cada 15 min era a
        alternativa óbvia e errada. Sem temporada na janela: 0, silencioso."""
        if now is None:
            now = int(time.time())
        row = con.execute(
            "SELECT season_id, ends_at FROM season WHERE status = 'active' "
            "AND ends_at > ? AND ends_at <= ? ORDER BY ends_at ASC LIMIT 1;",
            (now, now + int(lead_seconds))).fetchone()
        if not row:
            return 0
        season_id, ends_at = row
        marker = "season:%d" % season_id
        hours = max(1, int(round((int(ends_at) - now) / 3600.0)))
        rows = con.execute(
            "SELECT s.account_id FROM push_subscription s "
            "WHERE NOT EXISTS (SELECT 1 FROM push_outbox o "
            "                  WHERE o.account_id = s.account_id AND o.body LIKE ?);",
            (marker + "%",)).fetchall()
        for (acct,) in rows:
            self.push_enqueue(con, acct,
                              title="A temporada fecha em ~%dh" % hours,
                              body=marker, now=now)
        return len(rows)

    def push_campaign_open(self, con, lead_seconds=24 * 3600, now=None,
                           calendar_path=None):
        """M-4 (2026-10-07): o terceiro gancho do jogo — 'campanha abrindo'.
        Cada janela `double_xp`/`chest_bonus` do calendário LiveOps que ABRIR
        dentro de `lead_seconds` notifica TODO assinante UMA única vez por
        evento: a chave de dedupe mora no corpo da fila (`campaign:<key>`), o
        mesmo regime de `push_season_close` — restart não reabre a notificação.
        Diferença deliberada: IGUALDADE no corpo, não LIKE — as chaves têm
        underscore, e `_` é curinga do LIKE (prefixo solto trocaria aviso de
        uma campanha por outra). Torneio fica fora do gancho: é eixo de prize
        pool, não campanha jogável — a mesma isenção do pin Q-7. Calendário
        ilegível ou sem evento na janela: 0, silencioso — a régua é a mesma do
        'sem temporada na janela'."""
        if now is None:
            now = int(time.time())
        path = calendar_path or _server().default_liveops_calendar_path()
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
            events = doc.get("events", [])
        except (OSError, ValueError, AttributeError):
            return 0
        if not isinstance(events, list):
            return 0
        pushed = 0
        for ev in events:
            if not isinstance(ev, dict) or ev.get("kind") not in ("double_xp", "chest_bonus"):
                continue
            start = ev.get("start_unix")
            key = ev.get("key")
            if not isinstance(start, int) or not isinstance(key, str) or not key:
                continue
            if not (now < start <= now + int(lead_seconds)):
                continue
            marker = "campaign:%s" % key
            hours = max(1, int(round((start - now) / 3600.0)))
            label = ev.get("label")
            if not isinstance(label, str) or not label:
                label = "Campanha"
            rows = con.execute(
                "SELECT s.account_id FROM push_subscription s "
                "WHERE NOT EXISTS (SELECT 1 FROM push_outbox o "
                "                  WHERE o.account_id = s.account_id AND o.body = ?);",
                (marker,)).fetchall()
            for (acct,) in rows:
                self.push_enqueue(con, acct,
                                  title="Campanha abre em ~%dh: %s" % (hours, label),
                                  body=marker, now=now)
            pushed += len(rows)
        return pushed

    def push_drain(self, con, limit=20, sender=None, now=None):
        """Drena até `limit` linhas pending contra o sender plugável. Sucesso
        (retorno truthy) -> sent; NotImplementedError/qualquer exceção ->
        failed com last_error estável para o gate ler ('vapid_sender_' prefix).
        Sem subscription -> failed('no_subscription') (a fila não pode ficar
        presa por registro apagado). 404/410 do provedor -> o registro morto é
        apagado de push_subscription e a linha fica 'push_subscription_gone_N'
        (re-tentar subscription morta para sempre é pior que perder o aviso).
        Retry de failed é decisão de operador, não
        daqui. Retorna resumo; nunca levanta erro de envio para o chamador."""
        fn = sender or _server().push_sender()
        if now is None:
            now = int(time.time())
        summary = {"pending": 0, "sent": 0, "failed": 0, "skipped": 0}
        rows = con.execute(
            "SELECT o.id, o.account_id, o.title, o.body, "
            "       s.endpoint, s.p256dh, s.auth "
            "FROM push_outbox o LEFT JOIN push_subscription s "
            "     ON s.account_id = o.account_id "
            "WHERE o.status = 'pending' ORDER BY o.id LIMIT ?;",
            (int(limit),)).fetchall()
        total_pending = con.execute(
            "SELECT COUNT(*) FROM push_outbox WHERE status = 'pending';"
        ).fetchone()[0]
        summary["pending"] = total_pending
        for oid, acct, title, body, endpoint, p256dh, auth in rows:
            if not endpoint:
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = 'no_subscription' WHERE id = ?;",
                    (oid,))
                con.commit()
                summary["failed"] += 1
                continue
            sub = {"account_id": acct, "endpoint": endpoint,
                   "p256dh": p256dh, "auth": auth}
            try:
                delivered = bool(fn(sub, title, body))
            except NotImplementedError:
                # Mensagem do gate no harness: prefixo estável + detalhe só do
                # lado de fora do SQL (bind, nunca concatenação).
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    ("vapid_sender_unimplemented", oid))
                con.commit()
                summary["failed"] += 1
                continue
            except _server().PushSubscriptionGone as exc:
                # 404/410 (RFC 8030 §5.4): a subscription morreu no provedor.
                # Re-tentar para sempre é pior que perder o aviso — o registro
                # sai do banco e a linha confessa o motivo. Bind, nunca
                # concatenação de SQL.
                con.execute("DELETE FROM push_subscription WHERE account_id = ?;",
                            (acct,))
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    ("push_subscription_gone_%d" % exc.status, oid))
                con.commit()
                summary["failed"] += 1
                continue
            except Exception as e:
                con.execute(
                    "UPDATE push_outbox SET status = 'failed', attempts = "
                    "attempts + 1, last_error = ? WHERE id = ?;",
                    (str(type(e).__name__) + ": " + str(e)[:180], oid))
                con.commit()
                summary["failed"] += 1
                continue
            if delivered:
                con.execute(
                    "UPDATE push_outbox SET status = 'sent', attempts = "
                    "attempts + 1, sent_at = ?, last_error = NULL WHERE id = ?;",
                    (now, oid))
                con.commit()
                summary["sent"] += 1
            else:
                con.execute(
                    "UPDATE push_outbox SET attempts = attempts + 1, "
                    "last_error = 'sender_refused' WHERE id = ?;", (oid,))
                con.commit()
                summary["skipped"] += 1
        return summary
