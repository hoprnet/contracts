workspace "HOPR Smart Contracts Audit 10/2025" {
  !docs docs

    model {
        user = person "User"
        softwareSystem = softwareSystem "Software System"

        user -> softwareSystem "Uses"
    }

    views {
        systemContext softwareSystem "Diagram1" {
            include *
            autoLayout
        }
    }

}
