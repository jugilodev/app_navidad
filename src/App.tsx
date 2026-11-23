import { useCallback, useEffect, useState, type FormEvent } from 'react'
import {
  ArrowUpRight,
  Check,
  ChevronRight,
  Copy,
  Gift,
  Heart,
  Link as LinkIcon,
  LoaderCircle,
  LockKeyhole,
  MessageCircle,
  Plus,
  RefreshCw,
  Send,
  ShieldCheck,
  Snowflake,
  Trash2,
  TreePine,
  X,
} from 'lucide-react'
import { isSupabaseConfigured, supabase } from './lib/supabase'

type Member = { id: string; name: string }
type Wish = {
  id: string
  owner_id: string
  name: string
  url: string | null
  approximate_price: number | null
  description: string
}
type Question = {
  id: string
  recipient_id: string
  body: string
  answer: string | null
  created_at: string
}
type DrawResult = {
  member_id: string
  member_name: string
  recipient_id: string
  recipient_name: string
  is_admin: boolean
}
type InviteStatus = { id: string; name: string; has_invite: boolean; activated: boolean }
type WishDraft = { name: string; url: string; price: string; description: string }

const emptyDraft: WishDraft = { name: '', url: '', price: '', description: '' }

function messageFrom(error: unknown) {
  return error instanceof Error ? error.message : 'Ocurrió un error inesperado. Inténtalo de nuevo.'
}

async function backendErrorMessage(error: unknown) {
  if (error instanceof Error && 'context' in error && error.context instanceof Response) {
    try {
      const payload: unknown = await error.context.clone().json()
      if (typeof payload === 'object' && payload !== null && 'error' in payload && typeof payload.error === 'string') {
        return payload.error
      }
    } catch (parseError) {
      return `${error.message}: ${messageFrom(parseError)}`
    }
  }
  return messageFrom(error)
}

function App() {
  const [client] = useState(supabase)
  const [member, setMember] = useState<DrawResult | null>(null)
  const [members, setMembers] = useState<Member[]>([])
  const [wishes, setWishes] = useState<Wish[]>([])
  const [questions, setQuestions] = useState<Question[]>([])
  const [activeTab, setActiveTab] = useState<'deseos' | 'preguntas' | 'familia' | 'invitaciones'>('deseos')
  const [code, setCode] = useState('')
  const [invites, setInvites] = useState<InviteStatus[]>([])
  const [inviteLinks, setInviteLinks] = useState<Record<string, string>>({})
  const [draft, setDraft] = useState<WishDraft>(emptyDraft)
  const [editingWishId, setEditingWishId] = useState<string | null>(null)
  const [questionDraft, setQuestionDraft] = useState('')
  const [questionRecipient, setQuestionRecipient] = useState('')
  const [answerDraft, setAnswerDraft] = useState('')
  const [answeringQuestionId, setAnsweringQuestionId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  const loadFamilyContent = useCallback(async () => {
    if (!client) return
    const [membersResponse, wishesResponse, questionsResponse] = await Promise.all([
      client.from('family_members').select('id, name').order('name'),
      client.from('wishlists').select('id, owner_id, name, url, approximate_price, description').order('created_at', { ascending: false }),
      client.from('public_questions').select('id, recipient_id, body, answer, created_at').order('created_at', { ascending: false }),
    ])
    const failure = membersResponse.error ?? wishesResponse.error ?? questionsResponse.error
    if (failure) throw failure
    setMembers(membersResponse.data ?? [])
    setWishes(wishesResponse.data ?? [])
    setQuestions(questionsResponse.data ?? [])
  }, [client])

  const loadInviteStatus = useCallback(async () => {
    if (!client) return
    const { data, error: inviteError } = await client.functions.invoke('admin-invites', {
      body: { action: 'status' },
    })
    if (inviteError) throw new Error(await backendErrorMessage(inviteError))
    setInvites((data as { invites: InviteStatus[] }).invites)
  }, [client])

  const loadIdentity = useCallback(async (inviteCode?: string) => {
    if (!client) return
    const { data, error: invokeError } = await client.functions.invoke('redeem', {
      body: inviteCode ? { code: inviteCode } : {},
    })
    if (invokeError) throw new Error(await backendErrorMessage(invokeError))
    const identity = (data as { member: DrawResult | null }).member
    setMember(identity)
    if (identity) {
      setCode('')
      await loadFamilyContent()
      if (identity.is_admin) await loadInviteStatus()
    }
  }, [client, loadFamilyContent, loadInviteStatus])

  useEffect(() => {
    let active = true
    async function initialize() {
      if (!client) {
        setLoading(false)
        return
      }
      try {
        const inviteCode = new URLSearchParams(window.location.hash.slice(1)).get('codigo')
        if (inviteCode) {
          setCode(inviteCode)
          window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}`)
        }
        const { data, error: sessionError } = await client.auth.getSession()
        if (sessionError) throw sessionError
        if (!data.session) {
          const { error: signInError } = await client.auth.signInAnonymously()
          if (signInError) throw signInError
        }
        await loadIdentity(inviteCode ?? undefined)
      } catch (caught) {
        if (active) setError(messageFrom(caught))
      } finally {
        if (active) setLoading(false)
      }
    }
    void initialize()
    return () => { active = false }
  }, [client, loadIdentity])

  async function redeemCode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!client) return
    setSaving(true)
    setError('')
    try {
      const { data, error: invokeError } = await client.functions.invoke('redeem', {
        body: { code: code.trim().toUpperCase() },
      })
      if (invokeError) throw new Error(await backendErrorMessage(invokeError))
      const identity = (data as { member: DrawResult }).member
      setMember(identity)
      setCode('')
      await loadFamilyContent()
      if (identity.is_admin) await loadInviteStatus()
    } catch (caught) {
      setError(messageFrom(caught))
    } finally {
      setSaving(false)
    }
  }

  async function createInvite(invite: InviteStatus) {
    if (!client) return
    if (invite.has_invite && !window.confirm(`Al renovar la invitación de ${invite.name}, su enlace anterior dejará de funcionar y se cerrará su acceso actual. Su asignación secreta se conserva. ¿Quieres continuar?`)) {
      return
    }

    setSaving(true)
    setError('')
    try {
      const { data, error: inviteError } = await client.functions.invoke('admin-invites', {
        body: { action: 'create', member_id: invite.id },
      })
      if (inviteError) throw new Error(await backendErrorMessage(inviteError))

      const result = (data as { invite: { code: string } }).invite
      const invitationUrl = new URL(window.location.href)
      invitationUrl.hash = new URLSearchParams({ codigo: result.code }).toString()
      setInviteLinks((current) => ({ ...current, [invite.id]: invitationUrl.toString() }))
      setInvites((current) => current.map((item) => item.id === invite.id
        ? { ...item, has_invite: true, activated: false }
        : item))
      setNotice(`Enlace privado para ${invite.name} listo. Cópialo y envíaselo directamente; nadie verá el resultado del sorteo.`)
    } catch (caught) {
      setError(messageFrom(caught))
    } finally {
      setSaving(false)
    }
  }

  async function copyInviteLink(invite: InviteStatus) {
    const invitationUrl = inviteLinks[invite.id]
    if (!invitationUrl) return
    try {
      await navigator.clipboard.writeText(invitationUrl)
      setNotice(`Enlace privado de ${invite.name} copiado. Envíalo solo a esa persona.`)
    } catch (caught) {
      setError(`No se pudo copiar el enlace: ${messageFrom(caught)}. Selecciónalo y cópialo manualmente.`)
    }
  }

  async function saveWish(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!client || !member) return
    setSaving(true)
    setError('')
    const payload = {
      owner_id: member.member_id,
      name: draft.name.trim(),
      url: draft.url.trim() || null,
      approximate_price: draft.price ? Number(draft.price) : null,
      description: draft.description.trim(),
    }
    try {
      const result = editingWishId
        ? await client.from('wishlists').update(payload).eq('id', editingWishId)
        : await client.from('wishlists').insert(payload)
      if (result.error) throw result.error
      setDraft(emptyDraft)
      setEditingWishId(null)
      setNotice('Tu lista de deseos quedó actualizada.')
      await loadFamilyContent()
    } catch (caught) {
      setError(messageFrom(caught))
    } finally {
      setSaving(false)
    }
  }

  function editWish(wish: Wish) {
    setEditingWishId(wish.id)
    setDraft({
      name: wish.name,
      url: wish.url ?? '',
      price: wish.approximate_price?.toString() ?? '',
      description: wish.description,
    })
    document.getElementById('wishlist-form')?.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }

  async function removeWish(wishId: string) {
    if (!client || !window.confirm('¿Quieres quitar este deseo de tu lista?')) return
    setError('')
    const { error: deleteError } = await client.from('wishlists').delete().eq('id', wishId)
    if (deleteError) {
      setError(messageFrom(deleteError))
      return
    }
    setWishes((current) => current.filter((wish) => wish.id !== wishId))
    setNotice('Deseo eliminado de tu lista.')
  }

  async function askQuestion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!client || !questionRecipient) return
    setSaving(true)
    setError('')
    const { error: questionError } = await client.rpc('ask_question', {
      p_recipient_id: questionRecipient,
      p_body: questionDraft.trim(),
    })
    if (questionError) {
      setError(messageFrom(questionError))
    } else {
      setQuestionDraft('')
      setNotice('Tu pregunta anónima ya está en el buzón familiar.')
      try {
        await loadFamilyContent()
      } catch (caught) {
        setError(messageFrom(caught))
      }
    }
    setSaving(false)
  }

  async function answerQuestion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!client || !answeringQuestionId) return
    setSaving(true)
    setError('')
    const { error: answerError } = await client.rpc('answer_question', {
      p_question_id: answeringQuestionId,
      p_answer: answerDraft.trim(),
    })
    if (answerError) {
      setError(messageFrom(answerError))
    } else {
      setAnswerDraft('')
      setAnsweringQuestionId(null)
      setNotice('Tu respuesta ya está compartida con la familia.')
      try {
        await loadFamilyContent()
      } catch (caught) {
        setError(messageFrom(caught))
      }
    }
    setSaving(false)
  }

  if (!isSupabaseConfigured) {
    return <SetupScreen />
  }

  if (loading) {
    return <main className="loading-screen"><LoaderCircle className="spin" size={30} /><span>Preparando la Navidad...</span></main>
  }

  if (!member) {
    return (
      <main className="entry-screen">
        <div className="entry-decoration"><span>✦</span><span>✧</span><span>✦</span></div>
        <div className="entry-card">
          <div className="brand-mark"><TreePine size={22} /><span>Navidad en familia</span></div>
          <div className="entry-art" aria-hidden="true"><span className="art-star">✦</span><Gift size={55} strokeWidth={1.2} /><span className="art-sparkle">✧</span></div>
          <p className="eyebrow">Una pequeña sorpresa nos espera</p>
          <h1>La magia empieza<br />con tu código</h1>
          <p className="entry-copy">Ingresa el código privado que recibiste para descubrir a quién sorprenderás esta Navidad.</p>
          <form onSubmit={redeemCode} className="code-form">
            <label htmlFor="access-code">Tu código secreto</label>
            <input id="access-code" autoComplete="one-time-code" value={code} onChange={(event) => setCode(event.target.value)} placeholder="Ej. A1B2C3..." minLength={8} required />
            <button className="button button-primary full-width" type="submit" disabled={saving}>
              {saving ? <LoaderCircle className="spin" size={17} /> : <LockKeyhole size={17} />}
              Entrar a la celebración
              {!saving && <ChevronRight size={17} />}
            </button>
          </form>
          <div className="privacy-note"><LockKeyhole size={14} /> Tu código solo se puede usar en un dispositivo.</div>
          {error && <p className="message error-message">{error}</p>}
        </div>
        <p className="entry-footer">Hecho con cariño para compartir en familia <Heart size={13} fill="currentColor" /></p>
      </main>
    )
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="#inicio" onClick={() => setActiveTab('deseos')}><span className="brand-icon"><TreePine size={19} /></span><span>Navidad <em>en familia</em></span></a>
        <nav className="main-nav" aria-label="Navegación principal">
          <button className={activeTab === 'deseos' ? 'nav-link active' : 'nav-link'} onClick={() => setActiveTab('deseos')}>Lista de deseos</button>
          <button className={activeTab === 'preguntas' ? 'nav-link active' : 'nav-link'} onClick={() => setActiveTab('preguntas')}>Preguntas <span className="nav-count">{questions.length}</span></button>
          <button className={activeTab === 'familia' ? 'nav-link active' : 'nav-link'} onClick={() => setActiveTab('familia')}>La familia</button>
          {member.is_admin && <button className={activeTab === 'invitaciones' ? 'nav-link active' : 'nav-link'} onClick={() => setActiveTab('invitaciones')}>Invitaciones</button>}
        </nav>
        <div className="account-button" title="Sesión privada"><span className="avatar">{member.member_name.slice(0, 1)}</span><span className="account-name">{member.member_name}</span><LockKeyhole size={14} /></div>
      </header>

      <main id="inicio" className="page-content">
        <section className="welcome-banner">
          <div className="welcome-copy">
            <p className="eyebrow light-eyebrow"><Snowflake size={14} /> Diciembre sabe mejor juntos</p>
            <h1>Hola, {member.member_name}<span className="wave"> ✨</span></h1>
            <p>Este año te toca llenar de alegría a <strong>{member.recipient_name}</strong>.</p>
            <span className="gift-reveal"><Gift size={16} /> Tu amigo secreto</span>
          </div>
          <div className="banner-art" aria-hidden="true"><span className="banner-snow snow-one">✳</span><span className="banner-snow snow-two">✦</span><div className="present present-back"></div><div className="present present-front"><span></span></div><div className="banner-star">✧</div></div>
        </section>

        {(error || notice) && <div className={error ? 'message error-message app-message' : 'message success-message app-message'} role="status">{error || notice}<button aria-label="Cerrar mensaje" onClick={() => { setError(''); setNotice('') }}><X size={15} /></button></div>}

        <div className="section-heading">
          <div>
            <p className="eyebrow">{activeTab === 'deseos' ? 'Ideas para regalar' : activeTab === 'preguntas' ? 'Un buzón muy especial' : activeTab === 'invitaciones' ? 'Solo para quien organiza' : 'Nuestro pequeño mundo'}</p>
            <h2>{activeTab === 'deseos' ? 'Listas de deseos' : activeTab === 'preguntas' ? 'Preguntas anónimas' : activeTab === 'invitaciones' ? 'Invitaciones privadas' : 'La familia'}</h2>
          </div>
          <span className="section-caption"><Snowflake size={15} /> Una Navidad para recordar</span>
        </div>

        {activeTab === 'deseos' && (
          <section className="wish-layout">
            <div className="wish-groups">
              {members.map((person) => {
                const personWishes = wishes.filter((wish) => wish.owner_id === person.id)
                return (
                  <article className="member-wishes" key={person.id}>
                    <div className="member-heading"><div className="avatar avatar-small">{person.name.slice(0, 1)}</div><h3>{person.name}{person.id === member.member_id && <span className="you-label">Tú</span>}</h3><span className="wish-count">{personWishes.length} {personWishes.length === 1 ? 'deseo' : 'deseos'}</span></div>
                    {personWishes.length ? (
                      <div className="wish-list">
                        {personWishes.map((wish) => (
                          <article className="wish-card" key={wish.id}>
                            <div className="wish-icon"><Gift size={19} /></div>
                            <div className="wish-details"><h4>{wish.name}</h4>{wish.description && <p>{wish.description}</p>}{wish.approximate_price != null && <span className="price">Aprox. {Number(wish.approximate_price).toLocaleString('es-ES')}</span>}</div>
                            <div className="wish-actions">
                              {wish.url && <a className="icon-button" href={wish.url} target="_blank" rel="noreferrer" aria-label={`Ver enlace de ${wish.name}`}><ArrowUpRight size={17} /></a>}
                              {person.id === member.member_id && <><button className="icon-button" onClick={() => editWish(wish)} aria-label={`Editar ${wish.name}`}><span className="edit-glyph">✎</span></button><button className="icon-button danger-hover" onClick={() => void removeWish(wish.id)} aria-label={`Eliminar ${wish.name}`}><Trash2 size={16} /></button></>}
                            </div>
                          </article>
                        ))}
                      </div>
                    ) : <p className="empty-wishes">Todavía no hay deseos en esta lista.</p>}
                  </article>
                )
              })}
            </div>

            <aside className="wish-sidebar">
              <form id="wishlist-form" className="panel wish-form" onSubmit={saveWish}>
                <div className="panel-title"><span className="panel-icon"><Heart size={17} /></span><div><h3>{editingWishId ? 'Editar deseo' : 'Tu lista'}</h3><p>¿Qué te haría ilusión?</p></div></div>
                <label htmlFor="wish-name">Nombre del regalo</label>
                <input id="wish-name" maxLength={120} value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} placeholder="Un libro, una bufanda..." required />
                <label htmlFor="wish-url">Enlace de compra <span>(opcional)</span></label>
                <div className="input-with-icon"><LinkIcon size={15} /><input id="wish-url" type="url" value={draft.url} onChange={(event) => setDraft({ ...draft, url: event.target.value })} placeholder="https://" /></div>
                <label htmlFor="wish-price">Precio aproximado <span>(opcional)</span></label>
                <input id="wish-price" type="number" min="0" step="0.01" value={draft.price} onChange={(event) => setDraft({ ...draft, price: event.target.value })} placeholder="0.00" />
                <label htmlFor="wish-description">Un detalle más <span>(opcional)</span></label>
                <textarea id="wish-description" maxLength={2000} rows={3} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} placeholder="Color, talla, por qué te gusta..." />
                <button className="button button-primary full-width" type="submit" disabled={saving}>{saving ? <LoaderCircle className="spin" size={17} /> : <Plus size={17} />}{editingWishId ? 'Guardar cambios' : 'Añadir a mi lista'}</button>
                {editingWishId && <button className="text-button centered" type="button" onClick={() => { setEditingWishId(null); setDraft(emptyDraft) }}>Cancelar edición</button>}
              </form>
              <div className="tip-card"><span>❄</span><p><strong>Un secreto entre nosotros</strong>Tu lista es visible para todos, pero solo tú puedes añadir o cambiar tus deseos.</p></div>
            </aside>
          </section>
        )}

        {activeTab === 'preguntas' && (
          <section className="questions-layout">
            <div className="panel ask-panel">
              <div className="panel-title"><span className="panel-icon"><MessageCircle size={17} /></span><div><h3>Pregunta con confianza</h3><p>Tu nombre nunca aparecerá junto a la pregunta.</p></div></div>
              <form onSubmit={askQuestion}>
                <label htmlFor="question-recipient">¿A quién va dirigida?</label>
                <select id="question-recipient" value={questionRecipient} onChange={(event) => setQuestionRecipient(event.target.value)} required>
                  <option value="">Elige a alguien de la familia</option>
                  {members.filter((person) => person.id !== member.member_id).map((person) => <option value={person.id} key={person.id}>{person.name}</option>)}
                </select>
                <label htmlFor="question-body">Tu pregunta</label>
                <textarea id="question-body" rows={4} maxLength={1000} value={questionDraft} onChange={(event) => setQuestionDraft(event.target.value)} placeholder="¿Qué color te gusta más? ¿Hay algo que prefieras evitar?" required />
                <div className="form-footer"><span>{questionDraft.length}/1000</span><button className="button button-primary" type="submit" disabled={saving || !questionRecipient}><Send size={16} />Enviar anónimamente</button></div>
              </form>
              <p className="privacy-note"><LockKeyhole size={14} /> Las preguntas y respuestas se comparten con toda la familia, sin revelar quién preguntó.</p>
            </div>
            <div className="questions-list">
              <div className="subheading"><h3>Buzón familiar</h3><span>{questions.length} {questions.length === 1 ? 'mensaje' : 'mensajes'}</span></div>
              {questions.length ? questions.map((question) => {
                const recipient = members.find((person) => person.id === question.recipient_id)
                const isMyQuestion = question.recipient_id === member.member_id
                return (
                  <article className="question-card" key={question.id}>
                    <div className="question-topline"><span className="anonymous-badge"><LockKeyhole size={12} /> Anónimo</span><span>Para {recipient?.name ?? 'la familia'}</span></div>
                    <p className="question-body">{question.body}</p>
                    {question.answer ? <div className="answer-box"><span>Respuesta de {recipient?.name}</span><p>{question.answer}</p></div> : isMyQuestion ? answeringQuestionId === question.id ? (
                      <form className="answer-form" onSubmit={answerQuestion}><textarea rows={2} maxLength={1000} placeholder="Escribe tu respuesta para la familia..." value={answerDraft} onChange={(event) => setAnswerDraft(event.target.value)} required /><div className="answer-actions"><button className="text-button" type="button" onClick={() => setAnsweringQuestionId(null)}>Cancelar</button><button className="button button-primary button-small" disabled={saving}><Check size={14} />Responder</button></div></form>
                    ) : <button className="text-button answer-trigger" onClick={() => setAnsweringQuestionId(question.id)}>Responder a esta pregunta <ChevronRight size={15} /></button> : <div className="waiting-answer">Esperando una respuesta bonita...</div>}
                    <time>{new Date(question.created_at).toLocaleDateString('es-ES', { day: 'numeric', month: 'short' })}</time>
                  </article>
                )
              }) : <div className="empty-panel"><MessageCircle size={23} /><p>El buzón está esperando su primera pregunta.</p></div>}
            </div>
          </section>
        )}

        {activeTab === 'familia' && (
          <section className="family-grid">
            {members.map((person) => <article className="family-card" key={person.id}><div className="family-avatar">{person.name.slice(0, 1)}</div><h3>{person.name}{person.id === member.member_id && <span className="you-label">Tú</span>}</h3><p>{wishes.filter((wish) => wish.owner_id === person.id).length} deseos compartidos</p><button className="text-button" onClick={() => setActiveTab('deseos')}>Ver su lista <ChevronRight size={15} /></button></article>)}
          </section>
        )}

        {activeTab === 'invitaciones' && member.is_admin && (
          <section className="invite-management">
            <div className="invite-intro">
              <span className="invite-shield"><ShieldCheck size={21} /></span>
              <div>
                <h3>Una invitación distinta para cada persona</h3>
                <p>Crea un enlace y envíaselo en privado a cada familiar. Al abrirlo, su acceso queda vinculado y se hace únicamente su propio sorteo.</p>
              </div>
              <button className="button button-secondary refresh-button" onClick={() => void loadInviteStatus().catch((caught: unknown) => setError(messageFrom(caught)))}><RefreshCw size={15} />Actualizar</button>
            </div>
            <div className="invite-privacy"><LockKeyhole size={15} /><span>Administrar invitaciones no muestra ni cambia a quién le toca cada persona. Si renuevas un acceso, solo se invalida el enlace anterior; el sorteo permanece igual.</span></div>
            <div className="invite-list">
              {invites.map((invite) => {
                const link = inviteLinks[invite.id]
                return (
                  <article className="invite-row" key={invite.id}>
                    <div className="invite-person"><span className="avatar">{invite.name.slice(0, 1)}</span><div><h4>{invite.name}</h4><p>{invite.activated ? 'Acceso activado' : invite.has_invite ? 'Enlace pendiente de usar' : 'Aún no tiene invitación'}</p></div></div>
                    <div className="invite-actions">
                      {link && <button className="button button-secondary" onClick={() => void copyInviteLink(invite)}><Copy size={15} />Copiar enlace</button>}
                      <button className="button button-primary" disabled={saving} onClick={() => void createInvite(invite)}>
                        {saving ? <LoaderCircle className="spin" size={15} /> : invite.has_invite ? <RefreshCw size={15} /> : <Plus size={15} />}
                        {link ? 'Generar otro enlace' : invite.has_invite ? 'Renovar acceso' : 'Crear invitación'}
                      </button>
                    </div>
                    {link && <div className="invite-link-field"><LinkIcon size={14} /><input aria-label={`Enlace de invitación para ${invite.name}`} readOnly value={link} onFocus={(event) => event.currentTarget.select()} /></div>}
                  </article>
                )
              })}
            </div>
          </section>
        )}

        <footer className="page-footer"><span>Con cariño, para una Navidad inolvidable</span><span>✦</span><span>{members.length} personas reunidas</span></footer>
      </main>
    </div>
  )
}

function SetupScreen() {
  return (
    <main className="setup-screen">
      <div className="setup-card">
        <div className="brand-mark"><TreePine size={22} /><span>Navidad en familia</span></div>
        <h1>Un último paso antes de empezar</h1>
        <p>Esta app se conecta a Supabase. Configura las variables de entorno para que tu familia pueda acceder a sus listas y al sorteo.</p>
        <ol><li>Copia <code>.env.example</code> a <code>.env.local</code>.</li><li>Añade la URL del proyecto Supabase y la clave pública (<code>anon</code> o <code>publishable</code>).</li><li>Aplica la migración y el seed incluidos en <code>supabase/</code>.</li></ol>
      </div>
    </main>
  )
}

export default App
