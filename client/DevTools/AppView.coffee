class DevToolsMainView extends KDView

  COFFEE = "//cdnjs.cloudflare.com/ajax/libs/coffee-script/1.6.3/coffee-script.min.js"

  viewAppended:->

    @addSubView @workspace      = new CollaborativeWorkspace
      name                      : "Kodepad"
      delegate                  : this
      firebaseInstance          : "tw-local"
      panels                    : [
        title                   : "Koding DevTools"
        buttons                 : [
          {
            title               : "Create"
            callback            : KD.singletons.kodingAppsController.makeNewApp
          }
          {
            title               : "Run"
            callback            : @bound 'previewApp'
          }
          {
            title               : "Hide Filetree"
            itemClass           : KDToggleButton
            states              : [
              {
                title           : 'Hide Filetree'
                callback        : (cb)=>
                  @workspace.activePanel.layoutContainer
                    .splitViews.BaseSplit.resizePanel 0, 0, cb
              }
              {
                title           : 'Show Filetree'
                callback        : (cb)=>
                  @workspace.activePanel.layoutContainer
                    .splitViews.BaseSplit.resizePanel "258px", 0, cb
              }
            ]
  previewApp:->

    time 'Compile took:'

    return  if @_inprogress
    @_inprogress = yes

    {JSEditor, PreviewPane} = @workspace.activePanel.panesByName

    @compiler (coffee)=>

      code = JSEditor.getValue()

      PreviewPane.container.destroySubViews()
      window.appView = new KDView

      try

        coffee.compile code
        coffee.run code

        PreviewPane.container.addSubView window.appView

      catch e

        try window.appView.destroy?()
        warn "Compile failed:", e

      finally

        delete window.appView
        @_inprogress = no

        timeEnd 'Compile took:'

  previewCss:->

    {CSSEditor, PreviewPane} = @workspace.activePanel.panesByName

    @_css?.remove()

    @_css = $ "<style scoped></style>"
    @_css.html CSSEditor.getValue()

    PreviewPane.container.domElement.prepend @_css

  compiler:(callback)->

    return callback @coffee  if @coffee
    require [COFFEE], (@coffee)=> callback @coffee


class DevToolsEditorPane extends CollaborativeEditorPane

  setEditorTheme: ->
    if document.getElementById "codemirror-monokai-style"
      return  @codeMirrorEditor.setOption "theme", "monokai"

    link       = document.createElement "link"
    link.rel   = "stylesheet"
    link.type  = "text/css"
    link.href  = "#{cdnRoot}/theme/monokai.css"
    link.id    = "codemirror-monokai-style"
    document.head.appendChild link
    @codeMirrorEditor.setOption "theme", "monokai"


  createEditor: ->
    @codeMirrorEditor = CodeMirror @container.getDomElement()[0],
      lineNumbers     : yes
      scrollPastEnd   : yes
      cursorHeight    : 1
      tabSize         : 2
      mode            : "coffeescript"
      extraKeys       :
        "Cmd-S"       : @bound "handleSave"
        "Ctrl-S"      : @bound "handleSave"
        "Tab"         : (cm)->
          spaces = Array(cm.getOption("indentUnit") + 1).join " "
          cm.replaceSelection spaces, "end", "+input"

    @setEditorMode 'coffee'
