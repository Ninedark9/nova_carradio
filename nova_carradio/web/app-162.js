'use strict';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));
const resource = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'nova_carradio';

let appData = null;
let currentState = null;
let queue = [];
let favorites = [];
let history = [];
let playlists = [];
let activePlaylistId = null;
let currentTab = 'queue';
let progressPosition = 0;
let progressDuration = 0;
let preferredVolume = 55;
const sliderWrites = {
  volume: { timer: null, pending: false, queued: null },
  effects: { timer: null, pending: false, queued: null }
};
const activeRanges = new Set();
let seekEditing = false;
let seekDirty = false;
let seekPending = false;
let seekPreview = null;
let seekGeneration = 0;
let uiGeneration = 0;
let renderedTrack = null;
let analysisContext = null;
let analysisNode = null;
let analysisSource = null;
let analysisUrl = null;
let analysisAvailable = false;
let analyserData = null;
const scPlayers = new Map();

const clamp = (value, min, max) => Math.max(min, Math.min(max, Number(value) || 0));
const setRangeFill = (input, percent) => { if (!input) return; input.style.setProperty('--fill', `${clamp(percent, 0, 100)}%`); };
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (m) => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[m]));
const formatTime = (seconds) => {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0));
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
};
const parseLinks = (value) => Array.from(new Set(String(value || '').split(/\r?\n/).map((v) => v.trim()).filter(Boolean)));

const iconPaths = {
  play: '<path d="m9 5 11 7-11 7z"/>',
  heart: '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',
  remove: '<path d="m6 6 12 12M18 6 6 18"/>',
  music: '<path d="M9 18V5l11-2v13M9 8l11-2"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  arrow: '<path d="m9 5 7 7-7 7"/>',
  queue: '<path d="M4 6h16M4 12h12M4 18h8m5-3 4 3-4 3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>'
};
function icon(name) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths[name] || iconPaths.music}</svg>`;
}
function rowButton(actionName, label, glyph, attributes = '', classes = '') {
  return `<button type="button" class="row-icon ${classes}" data-action="${actionName}" ${attributes} title="${escapeHtml(label)}" aria-label="${escapeHtml(label)}">${icon(glyph)}</button>`;
}
function emptyState(title, instruction, glyph = 'music') {
  return `<div class="empty"><span class="empty-icon">${icon(glyph)}</span><strong>${escapeHtml(title)}</strong><p>${escapeHtml(instruction)}</p></div>`;
}

function sliderBusy(name) {
  const channel = sliderWrites[name];
  const editing = name === 'volume' ? activeRanges.has('volume') : [...activeRanges].some((id) => id.startsWith('dj-'));
  return editing || channel.timer !== null || channel.pending || channel.queued !== null;
}
async function flushSliderWrite(name) {
  const channel = sliderWrites[name];
  if (channel.pending || !channel.queued || !currentState || $('#app').hidden) return;
  const payload = channel.queued;
  channel.queued = null;
  channel.pending = true;
  try {
    await action(name, payload);
  } finally {
    channel.pending = false;
    // Serialize requests: a slow acknowledgement must not race a newer setting.
    if (channel.queued && channel.timer === null) flushSliderWrite(name);
  }
}
function queueSliderWrite(name, payload, delay) {
  const channel = sliderWrites[name];
  channel.queued = payload;
  if (channel.timer !== null) clearTimeout(channel.timer);
  channel.timer = setTimeout(() => {
    channel.timer = null;
    flushSliderWrite(name);
  }, delay);
}
function resetSliderInteractions() {
  activeRanges.clear();
  $$('input[type="range"]').forEach((input) => input.classList.remove('is-dragging'));
  for (const channel of Object.values(sliderWrites)) {
    if (channel.timer !== null) clearTimeout(channel.timer);
    channel.timer = null;
    channel.queued = null;
  }
  seekGeneration += 1;
  seekEditing = false;
  seekDirty = false;
  seekPending = false;
  seekPreview = null;
}

function detectProvider(url) {
  const value = String(url || '').toLowerCase();
  if (value.includes('youtube.com') || value.includes('youtu.be') || value.includes('youtube-nocookie.com')) return 'youtube';
  if (value.includes('soundcloud.com')) return 'soundcloud';
  if (/^https?:\/\//.test(value)) return 'direct';
  return 'auto';
}

async function post(action, payload = {}) {
  try {
    const response = await fetch(`https://${resource}/${action}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    return await response.json();
  } catch (_) {
    return { ok: false, error: 'NUI request failed.' };
  }
}

function showMessage(text, kind = 'error') {
  const node = $('#message');
  if (!text) {
    node.hidden = true;
    node.textContent = '';
    node.className = 'message';
    return;
  }
  node.hidden = false;
  node.textContent = text;
  node.className = `message ${kind === 'success' ? 'success' : ''}`;
}
function setSync(text) { const el = $('#sync-state'); if (el) el.textContent = String(text || 'READY').toUpperCase(); }
function setSourceChip() { const chip = $('#source-type'); const url = $('#url'); if (chip && url) chip.textContent = detectProvider(url.value).toUpperCase(); }
function setLoopUi(active) {
  const loop = $('#loop');
  if (!loop) return;
  loop.classList.toggle('active', !!active);
  loop.setAttribute('title', active ? 'Loop on' : 'Loop off');
  loop.setAttribute('aria-label', active ? 'Loop on' : 'Loop off');
  loop.setAttribute('aria-pressed', String(!!active));
}
function isFavorite(url) { return !!url && favorites.some((entry) => entry.url === url); }

function setCover(artwork) {
  const cover = $('#cover');
  if (artwork) {
    cover.classList.remove('fallback');
    cover.style.backgroundImage = `url("${String(artwork).replace(/"/g, '%22')}")`;
    cover.querySelector('.disc').style.display = 'none';
  } else {
    cover.classList.add('fallback');
    cover.style.backgroundImage = '';
    cover.querySelector('.disc').style.display = '';
  }
}

function renderFavoriteButton() {
  const active = currentState && isFavorite(currentState.url);
  $('#favorite').classList.toggle('active', !!active);
  $('#favorite-star').innerHTML = icon('heart');
  $('#favorite-label').textContent = active ? 'Saved to favorites' : 'Save to favorites';
  $('#favorite').setAttribute('aria-pressed', String(!!active));
  $('#favorite').setAttribute('aria-label', active ? 'Remove from favorites' : 'Save to favorites');
  $('#favorite').disabled = !currentState;
}

function setVolumeUi(value, send = false, force = false) {
  if (!send && !force && sliderBusy('volume')) return;
  preferredVolume = Math.round(clamp(value, 0, 100));
  $('#volume').value = String(preferredVolume);
  setRangeFill($('#volume'), preferredVolume);
  $('#volume-value').textContent = `${preferredVolume}%`;
  $('#volume').setAttribute('aria-valuetext', `${preferredVolume} percent`);
  if (send && currentState) {
    queueSliderWrite('volume', { volume: preferredVolume / 100 }, 90);
  }
}

const djPresets = {
  flat: { bass: 0, reverb: 0, distortion: 0, tempo: 1.0 },
  bass: { bass: 68, reverb: 4, distortion: 0, tempo: 1.0 },
  club: { bass: 40, reverb: 22, distortion: 5, tempo: 1.03 },
  lofi: { bass: 78, reverb: 16, distortion: 10, tempo: 0.92 }
};

function getDjUi() {
  return {
    bass: Math.round(clamp($('#dj-bass').value, 0, 100)),
    reverb: Math.round(clamp($('#dj-reverb').value, 0, 100)),
    distortion: Math.round(clamp($('#dj-distortion').value, 0, 100)),
    tempo: clamp(Number($('#dj-tempo').value) / 100, .75, 1.25)
  };
}

function updateDjLabels() {
  const fx = getDjUi();
  $('#dj-bass-value').textContent = `${fx.bass}%`;
  $('#dj-reverb-value').textContent = `${fx.reverb}%`;
  $('#dj-distortion-value').textContent = `${fx.distortion}%`;
  $('#dj-tempo-value').textContent = `${Math.round(fx.tempo * 100)}%`;
  ['bass', 'reverb', 'distortion', 'tempo'].forEach((name) => {
    const input = $(`#dj-${name}`);
    const value = Number(input.value);
    setRangeFill(input, ((value - Number(input.min)) / (Number(input.max) - Number(input.min))) * 100);
    input.setAttribute('aria-valuetext', `${value} percent`);
  });
  let presetName = 'CUSTOM';
  for (const [name, preset] of Object.entries(djPresets)) {
    if (Math.abs(fx.bass-preset.bass)<1 && Math.abs(fx.reverb-preset.reverb)<1 && Math.abs(fx.distortion-preset.distortion)<1 && Math.abs(fx.tempo-preset.tempo)<.011) { presetName = name.toUpperCase(); break; }
  }
  $('#dj-status').textContent = presetName;
  $$('.dj-preset').forEach((button) => {
    const active = button.dataset.djPreset === presetName.toLowerCase();
    button.classList.toggle('active', active);
    button.setAttribute('aria-pressed', String(active));
  });
}

function setDjUi(effects, send = false, force = false) {
  if (!send && !force && sliderBusy('effects')) return;
  const fx = effects || djPresets.flat;
  $('#dj-bass').value = String(Math.round(clamp(fx.bass ?? 0, 0, 100)));
  $('#dj-reverb').value = String(Math.round(clamp(fx.reverb ?? 0, 0, 100)));
  $('#dj-distortion').value = String(Math.round(clamp(fx.distortion ?? 0, 0, 100)));
  $('#dj-tempo').value = String(Math.round(clamp(fx.tempo ?? 1, .75, 1.25) * 100));
  updateDjLabels();
  if (send && currentState) {
    queueSliderWrite('effects', getDjUi(), 110);
  }
}

function renderState() {
  const state = currentState;
  const toggle = $('#toggle-play');
  const prev = $('#previous');
  const next = $('#next');
  const loop = $('#loop');
  const stop = $('#stop');
  const trackKey = state ? `${state.netId || ''}:${state.url || ''}` : null;
  const trackChanged = trackKey !== renderedTrack;
  if (trackChanged) {
    renderedTrack = trackKey;
    resetSliderInteractions();
    progressPosition = Number(state?.position) || 0;
    progressDuration = 0;
    renderProgress();
  }
  $('.radio')?.classList.toggle('is-playing', !!state?.playing);
  const playbackStatus = $('#playback-status');
  if (playbackStatus) playbackStatus.textContent = state ? (state.playing ? 'Now playing' : 'Paused') : 'Ready to play';
  toggle.setAttribute('aria-pressed', String(!!state?.playing));
  toggle.setAttribute('aria-label', state ? (state.playing ? 'Pause playback' : 'Resume playback') : 'Play');

  if (!state) {
    $('#provider').textContent = 'NO SOURCE';
    $('#title').textContent = 'No track loaded';
    $('#author').textContent = 'Paste a YouTube, SoundCloud or direct audio link.';
    setLoopUi(false);
    setCover('');
    setDjUi(djPresets.flat, false, true);
    $('#spectrum-mode').textContent = 'IDLE';
    progressPosition = 0;
    progressDuration = 0;
    renderProgress();
    renderFavoriteButton();
    toggle.classList.remove('is-playing');
    toggle.title = 'Play';
    toggle.disabled = true;
    prev.disabled = true;
    next.disabled = queue.length < 1;
    loop.disabled = true;
    stop.disabled = true;
    stopAnalysis();
    return;
  }

  $('#provider').textContent = String(state.provider || 'direct').toUpperCase();
  $('#title').textContent = state.title || 'Unknown track';
  $('#author').textContent = state.author || state.controller || 'Vehicle audio';
  setLoopUi(!!state.loop);
  setCover(state.artwork || '');
  setVolumeUi(Math.round(clamp(state.volume, 0, 1) * 100), false, trackChanged);
  setDjUi(state.effects || djPresets.flat, false, trackChanged);
  renderFavoriteButton();

  toggle.classList.toggle('is-playing', !!state.playing);
  toggle.title = state.playing ? 'Pause' : 'Resume';
  toggle.disabled = false;
  prev.disabled = false;
  next.disabled = false;
  loop.disabled = false;
  stop.disabled = false;

  if (state.provider === 'direct') {
    $('#spectrum-mode').textContent = state.playing ? 'VISUALIZER' : 'IDLE';
    startAnalysis(state);
  } else {
    $('#spectrum-mode').textContent = state.playing ? 'VISUALIZER' : 'IDLE';
    stopAnalysis();
  }
}

function renderProgress() {
  const previewing = seekEditing || seekPending;
  const position = previewing && seekPreview !== null ? seekPreview : progressPosition;
  $('#time-current').textContent = formatTime(position);
  $('#time-total').textContent = progressDuration > 0 ? formatTime(progressDuration) : '--:--';
  const seek = $('#seek');
  if (currentState && progressDuration > 0) {
    seek.disabled = false;
    if (!previewing) seek.value = String(Math.round(clamp(position / progressDuration, 0, 1) * 1000));
    setRangeFill(seek, (Number(seek.value) / 1000) * 100);
  } else {
    seek.disabled = true;
    seek.value = '0';
    setRangeFill(seek, 0);
  }
  seek.setAttribute('aria-valuetext', `${formatTime(position)} of ${progressDuration > 0 ? formatTime(progressDuration) : 'unknown duration'}`);
}

function entryPayload(entry) {
  if (!entry) return null;
  return { url: entry.url, provider: entry.provider, title: entry.title, author: entry.author, artwork: entry.artwork };
}

function rowHtml(entry, index, kind) {
  const artwork = entry.artwork ? `style="background-image:url(&quot;${escapeHtml(String(entry.artwork).replace(/["\\\r\n]/g, encodeURIComponent))}&quot;)"` : '';
  const subtitle = [entry.author || '', (entry.provider || 'direct').toUpperCase()].filter(Boolean).join(' · ');
  const saved = isFavorite(entry.url);
  const favorite = rowButton('favorite-row', saved ? 'Remove from favorites' : 'Save to favorites', 'heart', `data-kind="${kind}" data-index="${index}" aria-pressed="${saved}"`, saved ? 'fav-active' : '');
  const trackName = entry.title || 'Untitled';
  let actions = '';
  if (kind === 'queue') {
    actions = rowButton('queue-play', `Play ${trackName}`, 'play', `data-index="${index}"`) + favorite + rowButton('queue-remove', 'Remove from queue', 'remove', `data-index="${index}"`, 'danger');
  } else {
    actions = rowButton('library-play', `Play ${trackName}`, 'play', `data-kind="${kind}" data-index="${index}"`) + favorite;
  }
  return `<article class="track-row"><span class="track-no">${String(index + 1).padStart(2, '0')}</span><div class="mini-cover" ${artwork}>${artwork ? '' : icon('music')}</div><div class="track-info"><strong title="${escapeHtml(trackName)}">${escapeHtml(trackName)}</strong><span>${escapeHtml(subtitle || entry.url || '')}</span></div><div class="row-actions">${actions}</div></article>`;
}

function activePlaylist() { return playlists.find((p) => Number(p.id) === Number(activePlaylistId)) || null; }

function renderPlaylistManager() {
  const manager = $('#playlist-manager');
  const playlist = activePlaylist();
  const opening = manager.hidden;
  $('#list-playlists').classList.toggle('is-managing', !!playlist);
  if (!playlist) {
    manager.hidden = true;
    activePlaylistId = null;
    return;
  }
  manager.hidden = false;
  if (opening) $('#list-playlists').scrollTop = 0;
  const tracks = Array.isArray(playlist.tracks) ? playlist.tracks : [];
  $('#playlist-active-name').textContent = playlist.name || 'Playlist';
  $('#playlist-active-count').textContent = `${tracks.length} track${tracks.length === 1 ? '' : 's'}`;
  $('#playlist-rename-name').value = playlist.name || '';
  $('#playlist-track-list').innerHTML = tracks.length ? tracks.map((track, index) => {
    const subtitle = [track.author || '', (track.provider || 'direct').toUpperCase()].filter(Boolean).join(' · ');
    const attributes = `data-track-id="${Number(track.id)}"`;
    return `<article class="playlist-track"><span class="track-no">${String(index + 1).padStart(2, '0')}</span><div class="track-info"><strong>${escapeHtml(track.title || 'Untitled')}</strong><span>${escapeHtml(subtitle || track.url || '')}</span></div><div class="row-actions">${rowButton('playlist-track-play', `Play ${track.title || 'track'}`, 'play', attributes)}${rowButton('playlist-track-remove', 'Remove from playlist', 'remove', attributes, 'danger')}</div></article>`;
  }).join('') : emptyState('Make it your own', 'Paste a few links above to build this playlist.');
}

function renderPlaylists() {
  $('#playlist-list').innerHTML = playlists.length ? playlists.map((playlist) => {
    const count = Array.isArray(playlist.tracks) ? playlist.tracks.length : Number(playlist.trackCount) || 0;
    return `<article class="playlist-card" data-playlist-id="${Number(playlist.id)}"><span class="playlist-icon">${icon('queue')}</span><div><strong>${escapeHtml(playlist.name || 'Playlist')}</strong><span>${count} track${count === 1 ? '' : 's'}</span></div>${rowButton('playlist-open', `Open ${playlist.name || 'playlist'}`, 'arrow', `data-playlist-id="${Number(playlist.id)}"`)}</article>`;
  }).join('') : emptyState('Your next road trip mix', 'Create a playlist and keep your favorites together.', 'queue');
  renderPlaylistManager();
}

function renderLists() {
  $('#queue-count').textContent = String(queue.length);
  $('#list-queue').innerHTML = queue.length ? queue.map((entry, i) => rowHtml(entry, i, 'queue')).join('') : emptyState('Set the mood', 'Paste a link above and add your next track.', 'queue');
  $('#list-favorites').innerHTML = favorites.length ? favorites.map((entry, i) => rowHtml(entry, i, 'favorites')).join('') : emptyState('Keep the good ones', 'Tap the heart on a track to save it here.', 'heart');
  $('#list-history').innerHTML = history.length ? history.map((entry, i) => rowHtml(entry, i, 'history')).join('') : emptyState('Every drive has a soundtrack', 'Your recently played tracks will appear here.', 'clock');
  renderPlaylists();
  renderFavoriteButton();
}

function setTab(name) {
  currentTab = name;
  $$('.tab').forEach((button) => {
    const active = button.dataset.tab === name;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });
  $$('.list').forEach((node) => node.classList.toggle('active', node.id === `list-${name}`));
}

async function action(name, payload = {}) {
  const generation = uiGeneration;
  setSync('WORKING');
  const result = await post(name, payload);
  if (generation !== uiGeneration) return null;
  if (!result.ok) {
    setSync('ERROR');
    showMessage(result.error || 'Radio request failed.');
    return null;
  }
  showMessage('');
  setSync('SYNCED');
  const data = result.data || {};
  if (Object.prototype.hasOwnProperty.call(data, 'state')) currentState = data.state;
  if (data.queue) queue = data.queue;
  if (data.favorites) favorites = data.favorites;
  if (data.playlists) playlists = data.playlists;
  if (data.playlistId) activePlaylistId = Number(data.playlistId);
  if (data.entry && (name === 'play' || name === 'playlistTrackPlay' || name === 'previous' || name === 'next' || name === 'queuePlay')) {
    history.unshift(data.entry);
    if (history.length > 20) history.length = 20;
  }
  renderState();
  renderLists();
  setTimeout(() => setSync('READY'), 700);
  return data;
}

$('#url').addEventListener('input', setSourceChip);
$('#url').addEventListener('keydown', (event) => { if (event.key === 'Enter') $('#play-now').click(); });
$('#play-now').addEventListener('click', async () => {
  const url = $('#url').value.trim();
  if (!url) return showMessage('Paste a YouTube, SoundCloud or direct audio URL.');
  const data = await action('play', { url, volume: preferredVolume / 100, loop: !!currentState?.loop });
  if (data) $('#url').value = '';
  setSourceChip();
});
$('#add-queue').addEventListener('click', async () => {
  const url = $('#url').value.trim();
  if (!url) return showMessage('Paste a URL first.');
  const data = await action('queueAdd', { url });
  if (data) $('#url').value = '';
  setSourceChip();
});

$('#toggle-play').addEventListener('click', () => {
  if (!currentState) return showMessage('Nothing is loaded.');
  action(currentState.playing ? 'pause' : 'resume');
});
$('#previous').addEventListener('click', () => action('previous'));
$('#next').addEventListener('click', () => action('next'));
$('#stop').addEventListener('click', () => action('stop'));
$('#favorite').addEventListener('click', () => {
  if (!currentState) return showMessage('Nothing is playing.');
  action('favorite', entryPayload(currentState));
});
$('#loop').addEventListener('click', () => action('loop', { loop: !currentState?.loop }));
$('#volume').addEventListener('input', () => setVolumeUi(Number($('#volume').value), true));
$('#volume-down').addEventListener('click', () => {
  const step = Math.max(1, Math.round((Number(appData?.config?.volumeStep) || .05) * 100));
  setVolumeUi(preferredVolume - step, true);
});
$('#volume-up').addEventListener('click', () => {
  const step = Math.max(1, Math.round((Number(appData?.config?.volumeStep) || .05) * 100));
  setVolumeUi(preferredVolume + step, true);
});
['#dj-bass','#dj-reverb','#dj-distortion','#dj-tempo'].forEach((selector) => {
  $(selector).addEventListener('input', () => { updateDjLabels(); setDjUi(getDjUi(), true); });
});
$$('.dj-preset').forEach((button) => button.addEventListener('click', () => {
  const preset = djPresets[button.dataset.djPreset] || djPresets.flat;
  setDjUi(preset, true);
}));
function previewSeek() {
  if (!currentState || progressDuration <= 0) return;
  seekEditing = true;
  seekDirty = true;
  seekPreview = (Number($('#seek').value) / 1000) * progressDuration;
  renderProgress();
}
async function commitSeek() {
  if (!seekDirty || !currentState || progressDuration <= 0) return;
  const position = seekPreview;
  const generation = ++seekGeneration;
  seekDirty = false;
  seekPending = true;
  try {
    const result = await action('seek', { position });
    if (generation === seekGeneration && result) progressPosition = position;
  } finally {
    if (generation === seekGeneration) {
      seekPending = false;
      seekEditing = activeRanges.has('seek');
      if (!seekEditing) seekPreview = null;
      renderProgress();
    }
  }
}
function finishRange(input, cancelled = false) {
  activeRanges.delete(input.id);
  input.classList.remove('is-dragging');
  if (input.id !== 'seek') return;
  seekEditing = false;
  if (cancelled) {
    seekDirty = false;
    if (!seekPending) seekPreview = null;
    renderProgress();
  } else if (seekDirty) {
    commitSeek();
  } else if (!seekPending) {
    seekPreview = null;
    renderProgress();
  }
}
const rangeKeys = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown']);
$$('input[type="range"]').forEach((input) => {
  const begin = () => {
    if (input.disabled) return;
    activeRanges.add(input.id);
    input.classList.add('is-dragging');
    if (input.id === 'seek') seekEditing = true;
  };
  input.addEventListener('pointerdown', begin);
  input.addEventListener('pointerup', () => finishRange(input));
  input.addEventListener('pointercancel', () => finishRange(input, true));
  input.addEventListener('keydown', (event) => { if (rangeKeys.has(event.key)) begin(); });
  input.addEventListener('keyup', (event) => { if (rangeKeys.has(event.key)) finishRange(input); });
  input.addEventListener('blur', () => finishRange(input));
});
// Release outside the input still finishes the native range gesture.
window.addEventListener('pointerup', () => [...activeRanges].forEach((id) => {
  const input = $(`#${id}`);
  if (input) finishRange(input);
}));
window.addEventListener('blur', () => [...activeRanges].forEach((id) => {
  const input = $(`#${id}`);
  if (input) finishRange(input, true);
}));
$('#seek').addEventListener('input', previewSeek);
$('#seek').addEventListener('change', commitSeek);

$$('.tab').forEach((button) => button.addEventListener('click', () => setTab(button.dataset.tab)));

$('.library').addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) {
    const card = event.target.closest('.playlist-card[data-playlist-id]');
    if (card) { activePlaylistId = Number(card.dataset.playlistId); renderPlaylistManager(); }
    return;
  }
  const actionName = button.dataset.action;
  const index = Number(button.dataset.index);
  if (actionName === 'queue-play') return action('queuePlay', { index: index + 1 });
  if (actionName === 'queue-remove') return action('queueRemove', { index: index + 1 });
  if (actionName === 'library-play') {
    const list = button.dataset.kind === 'favorites' ? favorites : history;
    const entry = list[index];
    if (!entry) return;
    return action('play', { url: entry.url, volume: preferredVolume / 100, loop: !!currentState?.loop });
  }
  if (actionName === 'favorite-row') {
    const kind = button.dataset.kind;
    const list = kind === 'queue' ? queue : kind === 'favorites' ? favorites : history;
    const entry = list[index];
    if (entry) return action('favorite', entryPayload(entry));
  }
  if (actionName === 'playlist-open') {
    activePlaylistId = Number(button.dataset.playlistId);
    return renderPlaylistManager();
  }
  if (actionName === 'playlist-track-play') {
    if (!activePlaylistId) return;
    return action('playlistTrackPlay', { playlistId: activePlaylistId, trackId: Number(button.dataset.trackId), volume: preferredVolume / 100 });
  }
  if (actionName === 'playlist-track-remove') {
    if (!activePlaylistId) return;
    return action('playlistRemoveTrack', { playlistId: activePlaylistId, trackId: Number(button.dataset.trackId) });
  }
});

$('#playlist-create').addEventListener('click', async () => {
  const name = $('#playlist-name').value.trim();
  const urls = parseLinks($('#playlist-links').value);
  if (name.length < 2) return showMessage('Enter a playlist name.');
  const data = await action('playlistCreate', { name, urls });
  if (data) {
    $('#playlist-name').value = '';
    $('#playlist-links').value = '';
    setTab('playlists');
    showMessage(`Playlist created${urls.length ? ` with ${urls.length} link(s)` : ''}.`, 'success');
  }
});
$('#playlist-add').addEventListener('click', async () => {
  if (!activePlaylistId) return;
  const urls = parseLinks($('#playlist-add-links').value);
  if (!urls.length) return showMessage('Paste at least one link to add.');
  const data = await action('playlistAdd', { playlistId: activePlaylistId, urls });
  if (data) {
    $('#playlist-add-links').value = '';
    showMessage(`Added ${Number(data.added) || 0} track(s) to playlist.`, 'success');
  }
});
$('#playlist-play-all').addEventListener('click', () => {
  if (activePlaylistId) action('playlistPlay', { playlistId: activePlaylistId, mode: 'play', volume: preferredVolume / 100 });
});
$('#playlist-queue-all').addEventListener('click', () => {
  if (activePlaylistId) action('playlistPlay', { playlistId: activePlaylistId, mode: 'queue' });
});
$('#playlist-rename').addEventListener('click', () => {
  if (!activePlaylistId) return;
  const name = $('#playlist-rename-name').value.trim();
  if (name.length < 2) return showMessage('Enter a new playlist name.');
  action('playlistRename', { playlistId: activePlaylistId, name });
});
$('#playlist-delete').addEventListener('click', async () => {
  if (!activePlaylistId) return;
  const deleting = activePlaylistId;
  const data = await action('playlistDelete', { playlistId: deleting });
  if (data) { activePlaylistId = null; renderPlaylists(); showMessage('Playlist deleted.', 'success'); }
});
$('#playlist-close-manager').addEventListener('click', () => { activePlaylistId = null; renderPlaylistManager(); });

function closeRadio() {
  uiGeneration += 1;
  resetSliderInteractions();
  post('close');
}
$('#close').addEventListener('click', closeRadio);
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeRadio(); });

setRangeFill($('#seek'), 0);
setRangeFill($('#volume'), Number($('#volume').value || 55));
['#dj-bass','#dj-reverb','#dj-distortion','#dj-tempo'].forEach((selector) => { const el = $(selector); if (el) setRangeFill(el, selector === '#dj-tempo' ? ((Number(el.value)-75)/50)*100 : Number(el.value)); });

window.addEventListener('message', (event) => {
  const message = event.data || {};
  if (message.action === 'open') {
    uiGeneration += 1;
    resetSliderInteractions();
    appData = message.data || {};
    currentState = appData.state || null;
    queue = appData.queue || [];
    favorites = appData.favorites || [];
    history = appData.history || [];
    playlists = appData.playlists || [];
    preferredVolume = Math.round(clamp(currentState?.volume ?? appData.config?.defaultVolume ?? .55, 0, 1) * 100);
    const vehicle = appData.vehicle || {};
    const vehicleName = $('#vehicle-name'); if (vehicleName) vehicleName.textContent = vehicle.display || 'VEHICLE';
    const vehiclePlate = $('#vehicle-plate'); if (vehiclePlate) vehiclePlate.textContent = vehicle.plate || '--------';
    $('#app').hidden = false;
    setTab(currentTab);
    setVolumeUi(preferredVolume, false, true);
    setDjUi(currentState?.effects || djPresets.flat, false, true);
    renderState();
    renderLists();
    setSourceChip();
  } else if (message.action === 'close') {
    uiGeneration += 1;
    resetSliderInteractions();
    $('#app').hidden = true;
    showMessage('');
    stopAnalysis();
  } else if (message.action === 'radioState') {
    currentState = message.state || null;
    renderState();
  } else if (message.action === 'queue') {
    queue = message.queue || [];
    renderLists();
  } else if (message.action === 'actionResult') {
    // Lua also returns these data through the matching NUI fetch response.
    // action() applies that response with a UI-generation guard. Applying the
    // duplicate event could restore old controls after closing/reopening.
    return;
  } else if (message.action === 'progress') {
    progressPosition = Number(message.position) || 0;
    progressDuration = Number(message.duration) || 0;
    renderProgress();
  } else if (message.action && message.action.startsWith('sc:')) {
    handleSoundCloudMessage(message);
  }
});

// ---- Direct-stream analyser -------------------------------------------------
const analysisAudio = $('#analysis-audio');

function ensureAnalyser() {
  if (analysisNode) return true;
  try {
    analysisContext = new (window.AudioContext || window.webkitAudioContext)();
    analysisNode = analysisContext.createAnalyser();
    analysisNode.fftSize = 256;
    analysisNode.smoothingTimeConstant = 0.78;
    analyserData = new Uint8Array(analysisNode.frequencyBinCount);
    analysisSource = analysisContext.createMediaElementSource(analysisAudio);
    // Deliberately do not connect to destination: this element exists only to
    // analyse a direct URL. The audible stream is handled by oliSound.
    analysisSource.connect(analysisNode);
    return true;
  } catch (_) {
    analysisAvailable = false;
    return false;
  }
}

async function startAnalysis(state) {
  if (!state || state.provider !== 'direct' || !state.url) return stopAnalysis();
  if (!ensureAnalyser()) return;
  if (analysisUrl !== state.url) {
    analysisAudio.pause();
    analysisAudio.src = state.url;
    analysisAudio.currentTime = Number(state.position) || 0;
    analysisUrl = state.url;
  }
  if (state.playing) {
    try {
      if (analysisContext?.state === 'suspended') await analysisContext.resume();
      await analysisAudio.play();
      analysisAvailable = true;
    } catch (_) {
      analysisAvailable = false;
    }
  } else {
    analysisAudio.pause();
  }
}

function stopAnalysis() {
  analysisAudio.pause();
  analysisUrl = null;
  analysisAvailable = false;
}

// ---- SoundCloud widget engine ----------------------------------------------
function scApiReady() {
  return window.SC && window.SC.Widget;
}

function destroySc(id) {
  const entry = scPlayers.get(id);
  if (!entry) return;
  try { entry.widget?.pause(); } catch (_) {}
  entry.iframe?.remove();
  scPlayers.delete(id);
}

function createSc(message) {
  const id = String(message.id || '');
  if (!id || !message.url) return;
  destroySc(id);
  if (!scApiReady()) {
    setTimeout(() => createSc(message), 250);
    return;
  }
  const iframe = document.createElement('iframe');
  iframe.id = `sc-${id.replace(/[^a-zA-Z0-9_-]/g, '')}`;
  iframe.allow = 'autoplay';
  iframe.src = `https://w.soundcloud.com/player/?url=${encodeURIComponent(message.url)}&auto_play=true&hide_related=true&show_comments=false&show_user=false&show_reposts=false&visual=false`;
  $('#soundcloud-engine').appendChild(iframe);
  const widget = SC.Widget(iframe);
  const entry = { id, iframe, widget, token: message.token, position: Number(message.position) || 0, duration: 0, volume: Number(message.volume) || 0, playing: !!message.playing };
  scPlayers.set(id, entry);

  widget.bind(SC.Widget.Events.READY, () => {
    widget.setVolume(clamp(entry.volume, 0, 100));
    if (entry.position > 0) widget.seekTo(entry.position * 1000);
    if (entry.playing) widget.play(); else widget.pause();
    widget.getDuration((duration) => { entry.duration = Math.max(0, Number(duration) / 1000); });
  });
  widget.bind(SC.Widget.Events.PLAY_PROGRESS, (progress) => {
    entry.position = Math.max(0, Number(progress.currentPosition) / 1000);
    if (progress.relativePosition >= 0 && entry.duration <= 0) widget.getDuration((duration) => { entry.duration = Number(duration) / 1000; });
    if (currentState && id === `nova_carradio_${currentState.netId}`) {
      progressPosition = entry.position;
      progressDuration = entry.duration;
      renderProgress();
    }
  });
  widget.bind(SC.Widget.Events.FINISH, () => {
    post('soundcloudEnded', { id });
  });
}

function handleSoundCloudMessage(message) {
  const id = String(message.id || '');
  if (message.action === 'sc:create') return createSc(message);
  if (message.action === 'sc:destroy') return destroySc(id);
  const entry = scPlayers.get(id);
  if (!entry) return;
  if (message.action === 'sc:volume') {
    entry.volume = clamp(message.volume, 0, 100);
    try { entry.widget.setVolume(entry.volume); } catch (_) {}
  } else if (message.action === 'sc:pause') {
    entry.playing = false;
    try { entry.widget.pause(); } catch (_) {}
  } else if (message.action === 'sc:resume') {
    entry.playing = true;
    try { entry.widget.play(); } catch (_) {}
  } else if (message.action === 'sc:seek') {
    entry.position = Math.max(0, Number(message.position) || 0);
    try { entry.widget.seekTo(entry.position * 1000); } catch (_) {}
  }
}

// ---- Spectrum visualizer ----------------------------------------------------
const canvas = $('#visualizer');
const ctx = canvas.getContext('2d');
let visualTime = 0;
let smoothBars = [];

function resizeCanvas() {
  const rect = canvas.getBoundingClientRect();
  const dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
  const w = Math.max(1, Math.floor(rect.width * dpr));
  const h = Math.max(1, Math.floor(rect.height * dpr));
  if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
}

function syntheticLevel(index, count, time) {
  const bassRegion = 1 - Math.min(1, index / Math.max(1, count * 0.45));
  const beat = Math.max(0, Math.sin(time * 6.2) * 0.58 + Math.sin(time * 3.1 + 1.3) * 0.32);
  const ripple = (Math.sin(time * 4.4 + index * 0.72) + 1) * 0.19;
  const texture = (Math.sin(time * 10.7 + index * 1.61) + 1) * 0.08;
  return 0.08 + ripple + texture + bassRegion * beat * 0.76;
}

function drawVisualizer(timestamp) {
  if ($('#app').hidden) { requestAnimationFrame(drawVisualizer); return; }
  resizeCanvas();
  const width = canvas.width;
  const height = canvas.height;
  ctx.clearRect(0, 0, width, height);
  const bars = Number(appData?.config?.visualizerBars) || 32;
  const gap = Math.max(2, width * 0.004);
  const barWidth = Math.max(2, (width - gap * (bars - 1)) / bars);
  visualTime = timestamp / 1000;
  const playing = !!currentState?.playing;
  let fftUsable = false;

  if (playing && currentState?.provider === 'direct' && analysisAvailable && analysisNode && analyserData) {
    try {
      analysisNode.getByteFrequencyData(analyserData);
      let total = 0;
      for (let i = 0; i < 24 && i < analyserData.length; i++) total += analyserData[i];
      fftUsable = total > 20;
    } catch (_) {}
  }
  const spectrumMode = playing ? (fftUsable ? 'LIVE FFT' : 'VISUALIZER') : 'IDLE';
  if ($('#spectrum-mode').textContent !== spectrumMode) $('#spectrum-mode').textContent = spectrumMode;

  for (let i = 0; i < bars; i++) {
    let target = 0.055;
    if (playing) {
      if (fftUsable) {
        const start = Math.floor((i / bars) * analyserData.length * 0.72);
        const end = Math.max(start + 1, Math.floor(((i + 1) / bars) * analyserData.length * 0.72));
        let sum = 0;
        for (let k = start; k < end; k++) sum += analyserData[k] || 0;
        target = clamp((sum / (end - start)) / 255, 0.04, 1);
      } else {
        target = syntheticLevel(i, bars, visualTime);
      }
    }
    smoothBars[i] = (smoothBars[i] ?? 0.05) * 0.74 + target * 0.26;
    const h = Math.max(2, smoothBars[i] * height * 0.86);
    const x = i * (barWidth + gap);
    const y = height - h;
    const gradient = ctx.createLinearGradient(0, height, 0, 0);
    gradient.addColorStop(0, 'rgba(255,121,87,.36)');
    gradient.addColorStop(.65, '#ff7957');
    gradient.addColorStop(1, '#ffbd87');
    ctx.fillStyle = gradient;
    ctx.fillRect(x, y, barWidth, h);
  }
  requestAnimationFrame(drawVisualizer);
}

window.addEventListener('resize', resizeCanvas);
requestAnimationFrame(drawVisualizer);
renderProgress();
setSourceChip();
