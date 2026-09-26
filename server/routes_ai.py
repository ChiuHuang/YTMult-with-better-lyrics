# Split from proxy_server.py -- edit HERE, not the old monolith (now a thin shim).
#
# Admin API routes for AI providers (translate/retitle keys). Keys live in
# config/ai_providers.json (gitignored) + env vars; the list endpoint only
# ever exposes masked keys.
from flask import request, jsonify
from .app import app, login_required
from . import ai_providers as _aip


@app.route('/api/admin/ai/providers', methods=['GET'])
@login_required
def api_ai_providers():
    return jsonify({'ok': True, **_aip.list_masked()})


@app.route('/api/admin/ai/cohere', methods=['POST'])
@login_required
def api_ai_cohere_add():
    """Add a Cohere key. Body: {key}. Returns {ok, added}."""
    body = request.get_json(silent=True) or {}
    try:
        added = _aip.add_cohere_key(body.get('key') or '')
    except ValueError as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    return jsonify({'ok': True, 'added': added, **_aip.list_masked()})


@app.route('/api/admin/ai/cohere', methods=['DELETE'])
@login_required
def api_ai_cohere_del():
    """Remove a Cohere key. Body: {key} (full or masked form)."""
    body = request.get_json(silent=True) or {}
    n = _aip.remove_cohere_key((body.get('key') or '').strip())
    return jsonify({'ok': True, 'removed': n, **_aip.list_masked()})


@app.route('/api/admin/ai/chat', methods=['POST'])
@login_required
def api_ai_chat_add():
    """Add/replace an OpenAI-compatible chat provider. Body:
    {name, api_key, base_url?, model?, headers?, use_for?}.
    use_for subset of [translate, retitle]."""
    body = request.get_json(silent=True) or {}
    try:
        name = _aip.add_chat_provider(body)
    except ValueError as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    return jsonify({'ok': True, 'name': name, **_aip.list_masked()})


@app.route('/api/admin/ai/chat', methods=['DELETE'])
@login_required
def api_ai_chat_del():
    """Remove a chat provider. Body: {name}. File-backed only; the
    ORCAROUTER_API_KEY env entry cannot be removed here (unset the env)."""
    body = request.get_json(silent=True) or {}
    n = _aip.remove_chat_provider(body.get('name') or '')
    return jsonify({'ok': True, 'removed': n, **_aip.list_masked()})
