class CollaborativePanel extends Panel

  constructor: (options = {}, data) ->

    super options, data

    workspace      = @getDelegate()
    # panesLength    = @getOptions().panes.length
    createadPanes  = []

    @on "NewPaneCreated", (pane) =>
      createadPanes.push pane

      # if createadPanes.length is panesLength
      #   @getDelegate().emit "AllPanesAddedToPanel", @, createadPanes

  createHeaderButtons: ->
    super
    @header.addSubView new KDCustomHTMLView
      cssClass : "users"
      click    : => @getDelegate().showUsers()

  createHeaderHint: ->
    super
    @header.addSubView new KDCustomHTMLView
      cssClass : "session-key"
      partial  : @getDelegate().sessionKey
      tooltip  :
        title  : "This is your session key, you can share this key with your friends to work together."

  createPane: (paneOptions, targetContainer) ->
    PaneClass              = @getPaneClass paneOptions.type
    paneOptions.delegate   = @
    paneOptions.sessionKey = @getOptions().sessionKeys[@panes.length]  if @getOptions().sessionKeys
    isJoinedASession       = !!paneOptions.sessionKey and not @getDelegate().amIHost()

    if isJoinedASession
      if paneOptions.type is "terminal"
        PaneClass = SharableClientTerminalPane
      else if paneOptions.type is "finder"
        PaneClass = CollaborativeClientFinderPane

    return warn "Unknown pane class: #{paneOptions.type}"  unless PaneClass
    pane = new PaneClass paneOptions

    # targetContainer.addSubView pane
    @panes.push pane
    @emit "NewPaneCreated", pane
    return  pane

CollaborativePanel::EditorPaneClass        = CollaborativeEditorPane
CollaborativePanel::TerminalPaneClass      = SharableTerminalPane
CollaborativePanel::FinderPaneClass        = CollaborativeFinderPane
CollaborativePanel::TabbedEditorPaneClass  = CollaborativeTabbedEditorPane
CollaborativePanel::VideoPaneClass         = VideoPane
CollaborativePanel::PreviewPaneClass       = PreviewPane