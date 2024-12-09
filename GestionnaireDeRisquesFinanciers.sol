// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract GestionnaireDeRisquesFinanciers {
    // Structure représentant une position financière
    struct Position {
        uint256 montant;
        string typePosition;       // "LONG" ou "SHORT"
        uint256 timestamp;
        uint256 collateralExige;  // Collateral requis pour cette position
    }

    // Structure représentant une contrepartie
    struct Contrepartie {
        address portefeuille;
        uint256 scoreCredit;       // Entre 1 et 100
        uint256 limiteExposition;
        uint256 expositionCourante;
        uint256 collateral;        // Collateral total disponible
        Position[] historiquePositions;
        bool estActif;
        uint256 penalites;
    }

    // Mapping des contreparties par adresse
    mapping(address => Contrepartie) public contreparties;
    address[] public listeContreparties;

    // **Événements**
    event ContrepartieAjoutee(address indexed portefeuille, uint256 limiteExposition, uint256 collateral);
    event PositionAjoutee(address indexed portefeuille, uint256 montant, string typePosition, uint256 collateralExige);
    event LimiteDepassee(address indexed portefeuille, uint256 expositionCourante, uint256 limiteExposition);
    event RatioCouvertureInsuffisant(address indexed portefeuille, uint256 ratioCouverture);
    event PenaliteAppliquee(address indexed portefeuille, uint256 montantPenalite);

    // **Variables d'état**
    address public admin;
    uint256 public ratioDeCouverture = 120; // Ratio de couverture par défaut (120%)

    // **Modificateurs**
    modifier onlyAdmin() {
        require(msg.sender == admin, "Action reservee a l'administrateur");
        _;
    }

    modifier contrepartieActive(address _portefeuille) {
        require(contreparties[_portefeuille].estActif, "Contrepartie inactive ou inexistante");
        _;
    }

    // **Constructeur**
    constructor() {
        admin = msg.sender;
    }

    // **Fonctions Principales**

    /**
     * @dev Ajouter une nouvelle contrepartie.
     * @param _portefeuille Adresse de la contrepartie.
     * @param _scoreCredit Score de crédit de la contrepartie (1-100).
     * @param _limiteExposition Limite d'exposition de la contrepartie.
     * @param _collateral Collateral initial de la contrepartie.
     */
    function ajouterContrepartie(
        address _portefeuille,
        uint256 _scoreCredit,
        uint256 _limiteExposition,
        uint256 _collateral
    ) public onlyAdmin {
        require(_portefeuille != address(0), "Adresse invalide");
        require(!contreparties[_portefeuille].estActif, "Contrepartie existe deja");
        require(_scoreCredit > 0 && _scoreCredit <= 100, "Score de credit invalide");

        Contrepartie storage c = contreparties[_portefeuille];
        c.portefeuille = _portefeuille;
        c.scoreCredit = _scoreCredit;
        c.limiteExposition = _limiteExposition;
        c.expositionCourante = 0;
        c.collateral = _collateral;
        c.estActif = true;
        c.penalites = 0;

        listeContreparties.push(_portefeuille);

        emit ContrepartieAjoutee(_portefeuille, _limiteExposition, _collateral);
    }

    /**
     * @dev Obtenir la liste des contreparties actives.
     * @return Liste des adresses des contreparties actives.
     */
    function getListeContreparties() public view returns (address[] memory) {
        return listeContreparties;
    }

    /**
     * @dev Ajouter une position à une contrepartie.
     * @param _portefeuille Adresse de la contrepartie.
     * @param _montant Montant de la position.
     * @param _typePosition Type de la position ("LONG" ou "SHORT").
     */
    function ajouterPosition(
        address _portefeuille,
        uint256 _montant,
        string memory _typePosition
    ) public onlyAdmin contrepartieActive(_portefeuille) {
        require(_montant > 0, "Montant invalide");

        Contrepartie storage c = contreparties[_portefeuille];
        uint256 collateralExige = 0;

        if (keccak256(bytes(_typePosition)) == keccak256("LONG")) {
            c.expositionCourante += _montant;
        } else if (keccak256(bytes(_typePosition)) == keccak256("SHORT")) {
            collateralExige = (_montant * ratioDeCouverture) / 100;
            require(c.collateral >= collateralExige, "Collateral insuffisant pour cette position");

            c.collateral -= collateralExige;
            c.expositionCourante -= _montant;
        } else {
            revert("Type de position invalide, utiliser LONG ou SHORT");
        }

        c.historiquePositions.push(Position({
            montant: _montant,
            typePosition: _typePosition,
            timestamp: block.timestamp,
            collateralExige: collateralExige
        }));

        verifierDepassements(_portefeuille);

        emit PositionAjoutee(_portefeuille, _montant, _typePosition, collateralExige);
    }

    /**
     * @dev Calculer le ratio de couverture d'une contrepartie.
     * @param _portefeuille Adresse de la contrepartie.
     * @return Ratio de couverture en pourcentage.
     */
    function calculerRatioCouverture(address _portefeuille) public view contrepartieActive(_portefeuille) returns (uint256) {
        Contrepartie memory c = contreparties[_portefeuille];
        require(c.expositionCourante > 0, "Exposition courante nulle");
        return (c.collateral * 100) / c.expositionCourante;
    }

    /**
     * @dev Vérifier les dépassements et appliquer des pénalités si nécessaire.
     * @param _portefeuille Adresse de la contrepartie.
     */
    function verifierDepassements(address _portefeuille) internal {
        Contrepartie storage c = contreparties[_portefeuille];

        // Vérifier si l'exposition courante dépasse la limite
        if (c.expositionCourante > c.limiteExposition) {
            emit LimiteDepassee(_portefeuille, c.expositionCourante, c.limiteExposition);

            // Calculer et appliquer la pénalité
            uint256 montantPenalite = (c.expositionCourante - c.limiteExposition) * 10; // Exemple: 10 unités de pénalité par unité dépassée
            c.penalites += montantPenalite;
            emit PenaliteAppliquee(_portefeuille, montantPenalite);

            // Optionnel: Désactiver la contrepartie après dépassement
            c.estActif = false;
        }

        // Vérifier si le ratio de couverture est insuffisant
        uint256 ratioCouverture = calculerRatioCouverture(_portefeuille);
        if (ratioCouverture < 100) {
            emit RatioCouvertureInsuffisant(_portefeuille, ratioCouverture);
        }
    }

    /**
     * @dev Calculer l'exposition nette d'une contrepartie.
     * @param _portefeuille Adresse de la contrepartie.
     * @return Exposition nette en unités.
     */
    function calculerExpositionNette(address _portefeuille) public view contrepartieActive(_portefeuille) returns (int256) {
        Contrepartie memory c = contreparties[_portefeuille];
        int256 expositionNette = 0;

        for (uint256 i = 0; i < c.historiquePositions.length; i++) {
            Position memory p = c.historiquePositions[i];
            if (keccak256(bytes(p.typePosition)) == keccak256("LONG")) {
                expositionNette += int256(p.montant);
            } else {
                expositionNette -= int256(p.montant);
            }
        }

        return expositionNette;
    }

    /**
     * @dev Ajouter du collateral à une contrepartie.
     * @param _portefeuille Adresse de la contrepartie.
     * @param _montant Montant de collateral à ajouter.
     */
    function ajouterCollateral(address _portefeuille, uint256 _montant) public onlyAdmin contrepartieActive(_portefeuille) {
        require(_montant > 0, "Montant invalide");
        Contrepartie storage c = contreparties[_portefeuille];
        c.collateral += _montant;
    }

    /**
     * @dev Modifier le ratio de couverture global.
     * @param _nouveauRatio Nouveau ratio de couverture (>100).
     */
    function modifierRatioDeCouverture(uint256 _nouveauRatio) public onlyAdmin {
        require(_nouveauRatio > 100, "Le ratio doit etre superieur a 100%");
        ratioDeCouverture = _nouveauRatio;
    }
}
