import json
import sqlite3

from fastapi.testclient import TestClient

import main
from collectors.opencode import collect_opencode_usage


def test_health_and_capabilities(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.db")
    with TestClient(main.app) as client:
        health = client.get('/health')
        assert health.status_code == 200
        assert health.json()['status'] == 'ok'
        capabilities = client.get('/api/capabilities')
        assert capabilities.status_code == 200
        assert capabilities.json()['fts5'] is True
        assert capabilities.json()['sqlite_vec'] is True


def test_document_fts_search(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(main, "ollama_embedding", lambda _text: None)
    with TestClient(main.app) as client:
        created = client.post('/api/documents', json={
            'title': 'OpenCode database safety',
            'body': 'OpenCode usage metadata is read from a read-only SQLite database.',
            'source': 'test'
        })
        assert created.status_code == 200
        assert created.json()['indexed_fts5'] is True
        assert created.json()['indexed_vector'] is False
        result = client.post('/api/search', json={'query': 'OpenCode', 'limit': 5})
        assert result.status_code == 200
        assert result.json()['mode'] == 'lexical-only'
        assert result.json()['results'][0]['title'] == 'OpenCode database safety'


def test_vector_document_search(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "vector-test.db")
    vector = [0.0] * main.VECTOR_DIMENSIONS
    vector[0] = 1.0
    with TestClient(main.app) as client:
        created = client.post('/api/documents', json={
            'title': 'Vector indexed agent architecture',
            'body': 'The local vector index supports nearest-neighbour retrieval.',
            'source': 'vector-test', 'embedding': vector
        })
        assert created.status_code == 200
        assert created.json()['indexed_vector'] is True
        result = client.post('/api/search', json={
            'query': 'semantic architecture', 'embedding': vector, 'limit': 3
        })
        assert result.status_code == 200
        assert result.json()['mode'] == 'hybrid'
        assert result.json()['results'][0]['title'] == 'Vector indexed agent architecture'


def test_opencode_dual_store_contract_uses_v1_messages_and_v2_session_aggregates(tmp_path):
    source_path = tmp_path / 'opencode.db'
    source = sqlite3.connect(source_path)
    source.executescript('''
      CREATE TABLE session (id TEXT PRIMARY KEY, time_created INTEGER, parent_id TEXT);
      CREATE TABLE session_v2 (
        id TEXT PRIMARY KEY, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
        time_created INTEGER, time_updated INTEGER, fork_session_id TEXT
      );
      CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
      CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT, time_created INTEGER, seq INTEGER);
      CREATE TABLE auth (id TEXT PRIMARY KEY, data TEXT);
    ''')
    source.execute('INSERT INTO auth VALUES (?,?)', ('provider-secret', '{"apiKey":"DO_NOT_READ_OR_RETURN"}'))
    source.execute('INSERT INTO session VALUES (?,?,?)', ('legacy-session', 1770000000000, None))
    source.execute('INSERT INTO session VALUES (?,?,?)', ('legacy-fork', 1790000000000, 'legacy-session'))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('v2-session', json.dumps({'providerID': 'openai', 'id': 'gpt-test'}),
                    0.02, 100, 20, 5, 7, 3, 1770000000000, 1780000000000, None))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('forked-session', json.dumps({'providerID': 'openai', 'id': 'gpt-test'}),
                    0, 0, 0, 0, 0, 0, 1790000000000, 1790000000000, 'v2-session'))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('fallback-session', json.dumps({'providerID': 'anthropic', 'id': 'claude-test'}),
                    0.03, 300, 40, 10, 20, 5, 1770000000000, 1785000000000, None))
    assistant = {
        'role': 'assistant', 'providerID': 'openai', 'modelID': 'gpt-test',
        'time': {'created': 1780000000000},
        'tokens': {'input': 10, 'output': 2, 'reasoning': 1, 'cache': {'read': 0, 'write': 0}},
        'cost': 0.002, 'content': 'PRIVATE PROMPT AND ASSISTANT BODY MUST NOT BE RETURNED'
    }
    v2_assistant = {
        'model': {'providerID': 'openai', 'id': 'gpt-test'},
        'time': {'created': 1780000000000},
        'tokens': {'input': 80, 'output': 12, 'reasoning': 2, 'cache': {'read': 5, 'write': 1}},
        'cost': 0.01, 'content': [{'type': 'text', 'text': 'PRIVATE V2 BODY'}]
    }
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('v2-assistant-id', 'v2-session', 'assistant', json.dumps(v2_assistant), 1780000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('fallback-assistant-id', 'fallback-session', 'assistant', json.dumps({'content': 'PRIVATE FALLBACK BODY'}), 1785000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('compact-id', 'v2-session', 'compaction', json.dumps({'content': 'PRIVATE COMPACTION BODY'}), 1780000001000, 2))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('fork-copy', 'forked-session', 'assistant', json.dumps({**v2_assistant, 'content': [{'type':'text','text':'PRIVATE FORK BODY'}]}), 1780000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('user-prompt', 'v2-session', 'user', json.dumps({'content': 'PRIVATE USER PROMPT'}), 1780000000000, 3))
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('legacy-assistant-id', 'legacy-session', json.dumps(assistant), 1780000000000))
    # Same global message ID across stores is counted once.
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('v2-assistant-id', 'legacy-session', json.dumps(assistant), 1780000000000))
    # A copied pre-fork legacy row predating its fork session is excluded.
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('legacy-fork-copy', 'legacy-fork', json.dumps(assistant), 1780000000000))
    source.commit()
    source.close()

    original_stat = source_path.stat()
    envelope = collect_opencode_usage(source_path)
    after_stat = source_path.stat()
    records = envelope['records']
    assert envelope['schema_version'] == 1
    assert envelope['agent'] == 'opencode'
    assert envelope['status'] == 'ok'
    assert envelope['aggregation_basis'] == 'mixed'
    assert set(envelope['stores']) == {'message', 'session_message', 'session_v2'}
    assert len(records) == 3
    v2_record = next(record for record in records if record['session_id'] == 'v2-session')
    aggregate_record = next(record for record in records if record['message_type'] == 'session_aggregate')
    v1_record = next(record for record in records if record['session_id'] == 'legacy-session')
    assert v2_record['event_id'] == 'message:v2-assistant-id'
    assert v2_record['provider_id'] == 'openai' and v2_record['model_id'] == 'gpt-test'
    assert v2_record['input_tokens'] == 80 and v2_record['assistant_message_count'] == 1
    assert aggregate_record['session_id'] == 'fallback-session'
    assert aggregate_record['input_tokens'] == 300 and aggregate_record['assistant_message_count'] == 1
    assert v1_record['event_id'] == 'message:legacy-assistant-id'
    assert v1_record['input_tokens'] == 10 and v1_record['assistant_message_count'] == 1
    assert not any(record['session_id'] in {'legacy-fork', 'forked-session'} for record in records)
    encoded = json.dumps(envelope)
    for private_value in ('PRIVATE PROMPT', 'PRIVATE V2 BODY', 'PRIVATE FALLBACK BODY', 'PRIVATE COMPACTION BODY',
                          'PRIVATE FORK BODY', 'PRIVATE USER PROMPT', 'DO_NOT_READ_OR_RETURN'):
        assert private_value not in encoded
    assert envelope['privacy']['message_bodies_selected'] is False
    assert original_stat.st_size == after_stat.st_size
    assert original_stat.st_mtime_ns == after_stat.st_mtime_ns


def test_opencode_session_aggregate_schema_without_session_v2(tmp_path):
    source_path = tmp_path / 'opencode-session-v2.db'
    source = sqlite3.connect(source_path)
    source.executescript('''
      CREATE TABLE session (
        id TEXT PRIMARY KEY, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
        time_created INTEGER, time_updated INTEGER
      );
      CREATE TABLE session_message (
        id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT, time_created INTEGER, seq INTEGER
      );
    ''')
    source.execute('INSERT INTO session VALUES (?,?,?,?,?,?,?,?,?,?)',
                   ('new-schema-session', json.dumps({'providerID':'anthropic','id':'claude-test'}),
                    0.04, 200, 30, 8, 70, 10, 1770000000000, 1780000000000))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('message-1','new-schema-session','assistant','{"content":"private"}',1780000000000,1))
    source.commit(); source.close()
    envelope = collect_opencode_usage(source_path)
    assert envelope['aggregation_basis'] == 'session-aggregate'
    assert envelope['stores'] == ['session', 'session_message']
    assert len(envelope['records']) == 1
    assert envelope['records'][0]['provider_id'] == 'anthropic'
    assert envelope['records'][0]['assistant_message_count'] == 1
    assert 'private' not in json.dumps(envelope)


def test_host_snapshot_ingestion(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "snapshot-test.db")
    agents = [
        {"id": "opencode", "display_name": "OpenCode", "executable": "opencode", "installed": True},
        {"id": "claude", "display_name": "Claude Code", "executable": "claude", "installed": False},
        {"id": "codex", "display_name": "OpenAI Codex", "executable": "codex", "installed": True},
        {"id": "gemini", "display_name": "Gemini CLI", "executable": "gemini", "installed": False},
        {"id": "pi", "display_name": "Pi", "executable": "pi", "installed": False},
        {"id": "github-copilot", "display_name": "GitHub Copilot CLI", "executable": "copilot", "installed": False},
    ]
    snapshot = {
        "schema_version": 1,
        "collected_at": "2026-11-20T12:00:00+00:00",
        "agents": agents,
        "opencode": {
            "schema_version": 1, "agent": "opencode", "status": "available",
            "stores": ["message"], "error": None,
            "aggregation_basis": "message-level",
            "timestamp_semantics": "V1 assistant message creation timestamps.",
            "privacy": {"message_bodies_selected": False, "credentials_selected": False,
                        "source_database_modified": False},
            "records": [{
                "event_id": "snapshot-event-1", "session_id": "session-1",
                "provider_id": "openai", "model_id": "gpt-test", "message_type": "assistant",
                "created_at": "2026-11-20T11:00:00+00:00", "input_tokens": 12,
                "output_tokens": 8, "reasoning_tokens": 1, "cache_read_tokens": 2,
                "cache_write_tokens": 0, "cost_usd": 0.001
            }]
        }
    }
    with TestClient(main.app) as client:
        response = client.post('/api/ingest/host-snapshot', json=snapshot)
        assert response.status_code == 200, response.text
        assert response.json()['accepted'] is True
        agents_response = client.get('/api/agents')
        assert agents_response.status_code == 200
        assert next(item for item in agents_response.json()['agents'] if item['id'] == 'codex')['installed'] is True
        summary = client.get('/api/usage/summary').json()
        assert summary['assistant_messages'] == 1
        assert summary['input_output_tokens'] == 20
        assert summary['reasoning_tokens'] == 1
        assert summary['cache_read_tokens'] == 2
        status = client.get('/api/host-snapshot/status').json()
        assert status['opencode_status'] == 'available'


def test_v2_cumulative_session_snapshots_are_ingested_as_deltas(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "v2-delta-test.db")
    agents = [
        {"id": "opencode", "display_name": "OpenCode", "executable": "opencode", "installed": True},
        {"id": "claude", "display_name": "Claude Code", "executable": "claude", "installed": False},
        {"id": "codex", "display_name": "OpenAI Codex", "executable": "codex", "installed": False},
        {"id": "gemini", "display_name": "Gemini CLI", "executable": "gemini", "installed": False},
        {"id": "pi", "display_name": "Pi", "executable": "pi", "installed": False},
        {"id": "github-copilot", "display_name": "GitHub Copilot CLI", "executable": "copilot", "installed": False},
    ]
    def payload(collected_at, input_tokens, output_tokens, reasoning, cache_read, cache_write, cost, messages):
        return {
            "schema_version": 1, "collected_at": collected_at, "agents": agents,
            "opencode": {
                "schema_version": 1, "agent": "opencode", "status": "available",
                "stores": ["session_v2", "session_message"], "error": None,
                "aggregation_basis": "session-aggregate",
                "timestamp_semantics": "V2 cumulative session counters converted to observation-time deltas.",
                "privacy": {"message_bodies_selected": False, "credentials_selected": False,
                            "source_database_modified": False},
                "records": [{
                    "event_id": "session-aggregate:session_v2:session-1", "session_id": "session-1",
                    "provider_id": "openai", "model_id": "gpt-test", "message_type": "session_aggregate",
                    "created_at": collected_at, "assistant_message_count": messages,
                    "input_tokens": input_tokens, "output_tokens": output_tokens,
                    "reasoning_tokens": reasoning, "cache_read_tokens": cache_read,
                    "cache_write_tokens": cache_write, "cost_usd": cost
                }]
            }
        }
    with TestClient(main.app) as client:
        first = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:00:00+00:00',100,20,5,50,5,0.02,2))
        assert first.status_code == 200, first.text
        second = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:15:00+00:00',150,30,8,75,10,0.03,3))
        assert second.status_code == 200, second.text
        duplicate = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:15:00+00:00',150,30,8,75,10,0.03,3))
        assert duplicate.status_code == 200, duplicate.text
        # A counter decrease starts a new epoch. The new value is retained as
        # a positive delta and the reset is made visible to the UI/audit log.
        reset = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:30:00+00:00',10,2,1,5,1,0.004,1))
        assert reset.status_code == 200, reset.text
        reset_duplicate = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:30:00+00:00',10,2,1,5,1,0.004,1))
        assert reset_duplicate.status_code == 200, reset_duplicate.text
        summary = client.get('/api/usage/summary').json()
        assert summary['input_output_tokens'] == 192, summary
        assert summary['assistant_messages'] == 4, summary
        assert summary['reasoning_tokens'] == 9, summary
        assert summary['cache_read_tokens'] == 80, summary
        assert summary['cache_write_tokens'] == 11, summary
        assert abs(summary['cost_usd'] - 0.034) < 1e-9, summary
        assert summary['usage_events'] == 3, summary
        assert summary['counter_reset_events'] == 1, summary


def test_embedding_dimension_validation():
    try:
        main.validate_embedding([0.1, 0.2])
    except Exception as exc:
        assert getattr(exc, 'status_code', None) == 422
    else:
        raise AssertionError('Invalid vector dimension was accepted')
