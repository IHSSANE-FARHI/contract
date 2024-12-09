// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract GestionnaireRisqueContrepartie {
    // Structures de données
    struct Position {
        uint256 montant;
        string typePosition; // "LONG" ou "SHORT"
        uint256 timestamp;
        uint256 collateralExige;
    }

    struct Contrepartie {
        address portefeuille;
        uint256 scoreCredit; // Entre 1 et 100
        uint256 limiteExposition;
        uint256 expositionCourante;
        uint256 collateral;
        Position[] historiquePositions;
        bool estActif;
        uint256 penalites;
        uint256 garantie;
    }

    struct EnregistrementTransaction {
        address expediteur;
        address recepteur;
        int256 valeur;
        uint256 horodatage;
    }

    // Variables d'état
    address public admin;
    uint256 public ratioDeCouverture = 120; // Ratio de couverture par défaut (120%)

    mapping(address => Contrepartie) public contreparties;
    address[] public listeContreparties;

    // Mapping pour suivre les expositions entre contreparties
    mapping(address => mapping(address => int256)) public relationsExposition;

    // Historique global des transactions
    EnregistrementTransaction[] public historiqueTransactions;

    // **Événements**
    event ContrepartieAjoutee(address indexed portefeuille, uint256 limiteExposition, uint256 collateral);
    event PositionAjoutee(address indexed portefeuille, uint256 montant, string typePosition, uint256 collateralExige);
    event LimiteDepassee(address indexed portefeuille, uint256 expositionCourante, uint256 limiteExposition);
    event RatioCouvertureInsuffisant(address indexed portefeuille, uint256 ratioCouverture);
    event PenaliteAppliquee(address indexed portefeuille, uint256 montantPenalite);
    event NouvelleOperation(address indexed expediteur, address indexed recepteur, int256 valeur, uint256 horodatage);
    event AlerteRisqueEleve(address indexed portefeuille, string typeAlerte, uint256 valeur);
    event MiseAJourGarantie(address indexed portefeuille, uint256 nouvelleGarantie);
    event FondsEnvoyes(address indexed expediteur, address indexed recepteur, uint256 montant);

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

    // Ajouter une nouvelle contrepartie
    function ajouterContrepartie(address _portefeuille, uint256 _scoreCredit, uint256 _limiteExposition, uint256 _collateral) 
        public 
        onlyAdmin 
    {
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
        c.garantie = 0;

        listeContreparties.push(_portefeuille);

        emit ContrepartieAjoutee(_portefeuille, _limiteExposition, _collateral);
    }

    // Obtenir la liste des contreparties
    function getListeContreparties() public view returns (address[] memory) {
        return listeContreparties;
    }

    // Ajouter une position
    function ajouterPosition(address _portefeuille, uint256 _montant, string memory _typePosition) 
        public 
        onlyAdmin 
        contrepartieActive(_portefeuille) 
    {
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

    // Calculer le ratio de couverture
    function calculerRatioCouverture(address _portefeuille) 
        public 
        view 
        contrepartieActive(_portefeuille) 
        returns (uint256) 
    {
        Contrepartie memory c = contreparties[_portefeuille];
        require(c.expositionCourante > 0, "Exposition courante nulle");
        return (c.collateral * 100) / c.expositionCourante;
    }

    // Vérifier les dépassements et appliquer des pénalités
    function verifierDepassements(address _portefeuille) internal {
        Contrepartie storage c = contreparties[_portefeuille];

        if (c.expositionCourante > c.limiteExposition) {
            emit LimiteDepassee(_portefeuille, c.expositionCourante, c.limiteExposition);
            // Désactivation de la contrepartie si nécessaire
            c.estActif = false;
            // Application de pénalités
            uint256 montantPenalite = (c.expositionCourante - c.limiteExposition) * 10; // Exemple de calcul de pénalité
            c.penalites += montantPenalite;
            emit PenaliteAppliquee(_portefeuille, montantPenalite);
        }

        uint256 ratioCouverture = calculerRatioCouverture(_portefeuille);
        if (ratioCouverture < 100) {
            emit RatioCouvertureInsuffisant(_portefeuille, ratioCouverture);
            emit AlerteRisqueEleve(_portefeuille, "Garantie insuffisante", ratioCouverture);
        }

        uint256 risque = calculerRisque(_portefeuille);
        if (risque > 200) {
            emit AlerteRisqueEleve(_portefeuille, "Risque eleve", risque);
        }
    }

    // Calculer l'exposition nette
    function calculerExpositionNette(address _portefeuille) 
        public 
        view 
        contrepartieActive(_portefeuille) 
        returns (int256) 
    {
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

    // Ajouter du collateral
    function ajouterCollateral(address _portefeuille, uint256 _montant) 
        public 
        onlyAdmin 
        contrepartieActive(_portefeuille) 
    {
        require(_montant > 0, "Montant invalide");
        Contrepartie storage c = contreparties[_portefeuille];
        c.collateral += _montant;
    }

    // Modifier le ratio de couverture global
    function modifierRatioDeCouverture(uint256 _nouveauRatio) 
        public 
        onlyAdmin 
    {
        require(_nouveauRatio > 100, "Le ratio doit etre superieur a 100%");
        ratioDeCouverture = _nouveauRatio;
    }

    // **Fonctions Supplémentaires**

    // Enregistrer une transaction entre deux contreparties
    function enregistrerTransaction(address _recepteur, int256 _valeur) 
        public 
        contrepartieActive(msg.sender) 
        contrepartieActive(_recepteur) 
    {
        require(_recepteur != address(0), "Adresse recepteur invalide");
        require(_valeur != 0, "Valeur invalide");

        // Mettre à jour les expositions
        relationsExposition[msg.sender][_recepteur] += _valeur;

        // Enregistrer l'historique des transactions
        historiqueTransactions.push(EnregistrementTransaction({
            expediteur: msg.sender,
            recepteur: _recepteur,
            valeur: _valeur,
            horodatage: block.timestamp
        }));

        emit NouvelleOperation(msg.sender, _recepteur, _valeur, block.timestamp);

        // Vérifier les limites après la transaction
        verifierDepassements(msg.sender);
        verifierDepassements(_recepteur);
    }

    // Ajouter ou mettre à jour la garantie d'une contrepartie
    function actualiserGarantie(address _portefeuille, uint256 _nouvelleGarantie) 
        public 
        onlyAdmin 
        contrepartieActive(_portefeuille) 
    {
        require(_nouvelleGarantie > 0, "Garantie invalide");
        Contrepartie storage c = contreparties[_portefeuille];
        c.garantie = _nouvelleGarantie;

        emit MiseAJourGarantie(_portefeuille, _nouvelleGarantie);

        // Vérifier les limites après mise à jour de la garantie
        verifierDepassements(_portefeuille);
    }

    // Calculer le risque basé sur l'exposition, la limite et le score de crédit
    function calculerRisque(address _portefeuille) 
        public 
        view 
        contrepartieActive(_portefeuille) 
        returns (uint256) 
    {
        Contrepartie memory c = contreparties[_portefeuille];
        require(c.limiteExposition > 0 && c.scoreCredit > 0, "Parametres invalides");
        return (c.expositionCourante * 10000) / (c.limiteExposition * c.scoreCredit);
    }

    // Calculer le ratio de garantie
    function calculerRatioGarantie(address _portefeuille) 
        public 
        view 
        contrepartieActive(_portefeuille) 
        returns (uint256) 
    {
        Contrepartie memory c = contreparties[_portefeuille];
        return c.expositionCourante == 0 ? 100 : (c.garantie * 100) / c.expositionCourante;
    }

    // Fonction pour envoyer des fonds d'une contrepartie à une autre (Optionnel)
    function envoyerFonds(address payable _recepteur, uint256 _montant) 
        public 
        onlyAdmin 
        contrepartieActive(msg.sender) 
        contrepartieActive(_recepteur) 
    {
        require(_recepteur != address(0), "Adresse recepteur invalide");
        require(_montant > 0, "Montant invalide");
        require(address(this).balance >= _montant, "Solde insuffisant dans le contrat");

        // Transférer les fonds
        (bool success, ) = _recepteur.call{value: _montant}("");
        require(success, "Transfert echoue");

        // Enregistrer la transaction
        enregistrerTransaction(_recepteur, int256(_montant));

        emit FondsEnvoyes(msg.sender, _recepteur, _montant);
    }

    // Fonction pour recevoir des fonds dans le contrat
    receive() external payable {
        // Logique additionnelle si nécessaire
    }

    // Vérifier les limites d'exposition et de garantie, et émettre des alertes si nécessaire
    function verifierLimites(address _portefeuille) internal {
        Contrepartie storage c = contreparties[_portefeuille];
        uint256 ratioGarantie = calculerRatioGarantie(_portefeuille);
        uint256 risque = calculerRisque(_portefeuille);

        // Vérifier si l'exposition dépasse la limite
        if (c.expositionCourante > c.limiteExposition) {
            c.estActif = false;
            emit LimiteDepassee(_portefeuille, c.expositionCourante, c.limiteExposition);
            // Application de pénalités (exemple)
            uint256 montantPenalite = (c.expositionCourante - c.limiteExposition) * 10; // Exemple de calcul de pénalité
            c.penalites += montantPenalite;
            emit PenaliteAppliquee(_portefeuille, montantPenalite);
        }

        // Vérifier si le ratio de couverture est insuffisant
        if (ratioGarantie < 50) {
            emit RatioCouvertureInsuffisant(_portefeuille, ratioGarantie);
            emit AlerteRisqueEleve(_portefeuille, "Garantie insuffisante", ratioGarantie);
        }

        // Vérifier si le risque est élevé
        if (risque > 200) {
            emit AlerteRisqueEleve(_portefeuille, "Risque eleve", risque);
        }
    }

    // Obtenir l'historique des transactions
    function obtenirHistoriqueTransactions() public view returns (EnregistrementTransaction[] memory) {
        return historiqueTransactions;
    }
}
