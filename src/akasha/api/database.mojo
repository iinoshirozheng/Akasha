struct DatabaseConfig(Copyable, Movable, Writable):
    var name: String
    var format_version: Int

    def __init__(out self, var name: String, format_version: Int):
        self.name = name^
        self.format_version = format_version
