import EngineBindings
import Shared

extension Hit {
    /// The UI's card projection of a search hit.
    var mini: Card.Mini {
        Card.Mini(id: id, name: name, colors: colors, setCode: setCode, setName: setName, rarity: rarity)
    }
}
