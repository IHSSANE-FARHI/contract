// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract GestionnaireDeRisquesFinanciers {

    struct Position {
        uint256 montant;
        string typePosition; // "LONG" ou "SHORT"
        uint256 timestamp;
    }

    struct Contrepartie {
        address portefeuille;
        uint256 scoreCredit;       // Doit être entre 1 et 100
        uint256 limiteExposition;
        uint256 expositionCourante;
        uint256 collateral;
        Position[] historiquePositions;
        bool estActif;
        uint256 penalites;
    }

    mapping(address => Contrepartie) public contreparties;
    address[] public listeContreparties;
    mapping(address => uint256) public nombreDepassements;

    // Événements
    event ContrepartieAjoutee(address indexed portefeuille, uint256 limiteExposition, uint256 collateral);
    event PositionAjoutee(address indexed portefeuille, uint256 montant, string typePosition);
    event LimiteDepassee(address indexed portefeuille, uint256 expositionCourante, uint256 limiteExposition);
    event RatioCouvertureInsuffisant(address indexed portefeuille, uint256 ratioCouverture);
    event ContrepartieDesactivee(address indexed portefeuille);
    event PenaliteAppliquee(address indexed portefeuille, uint256 montantPenalite);
    event CollateralMisAJour(address indexed portefeuille, uint256 nouveauCollateral);

    /**
     * @notice Ajouter une contrepartie avec un score de crédit, une limite d’exposition et un collatéral initial.
     * @param _portefeuille Adresse du portefeuille de la contrepartie
     * @param _scoreCredit Score de crédit (1-100)
     * @param _limiteExposition Limite d’exposition autorisée
     * @param _collateral Montant initial de collatéral
     */
    function ajouterContrepartie(address _portefeuille, uint256 _scoreCredit, uint256 _limiteExposition, uint256 _collateral) public {
        require(_portefeuille != address(0), "Adresse invalide");
        require(!contreparties[_portefeuille].estActif, "Contrepartie existe deja");
        require(_limiteExposition > 0, "La limite d'exposition doit etre positive");
        require(_scoreCredit > 0 && _scoreCredit <= 100, "Score de credit invalide");

        Contrepartie storage nouvelleContrepartie = contreparties[_portefeuille];
        nouvelleContrepartie.portefeuille = _portefeuille;
        nouvelleContrepartie.scoreCredit = _scoreCredit;
        nouvelleContrepartie.limiteExposition = _limiteExposition;
        nouvelleContrepartie.expositionCourante = 0;
        nouvelleContrepartie.collateral = _collateral;
        nouvelleContrepartie.estActif = true;
        nouvelleContrepartie.penalites = 0;

        listeContreparties.push(_portefeuille);

        emit ContrepartieAjoutee(_portefeuille, _limiteExposition, _collateral);
    }

    /**
     * @notice Ajouter une position (LONG ou SHORT) pour une contrepartie et mettre à jour son exposition.
     * @param _portefeuille Adresse du portefeuille de la contrepartie
     * @param _montant Montant de la position
     * @param _typePosition "LONG" ou "SHORT"
     */
    function ajouterPosition(address _portefeuille, uint256 _montant, string memory _typePosition) public {
        require(contreparties[_portefeuille].estActif, "Contrepartie inactive");
        require(bytes(_typePosition).length > 0, "Type de position invalide");
        require(_montant > 0, "Le montant doit etre superieur a 0");

        Contrepartie storage c = contreparties[_portefeuille];

        // Mise à jour de l'historique
        c.historiquePositions.push(Position({
            montant: _montant,
            typePosition: _typePosition,
            timestamp: block.timestamp
        }));

        // Mise à jour de l’exposition en fonction du type de position
        // On suppose "LONG" => ajout à l'exposition, "SHORT" => diminution de l'exposition
        bytes32 posType = keccak256(bytes(_typePosition));
        if (posType == keccak256("LONG")) {
            c.expositionCourante += _montant;
        } else if (posType == keccak256("SHORT")) {
            // On ne descend pas en négatif, l'exposition ne devant pas être < 0
            if (c.expositionCourante > _montant) {
                c.expositionCourante -= _montant;
            } else {
                c.expositionCourante = 0;
            }
        } else {
            revert("Type de position inconnu, utiliser LONG ou SHORT");
        }

        // Vérification des limites après mise à jour de l’exposition
        verifierDepassements(_portefeuille);

        emit PositionAjoutee(_portefeuille, _montant, _typePosition);
    }

    /**
     * @notice Calcul du ratio de couverture = (Collatéral / Exposition Courante) * 100
     */
    function calculerRatioCouverture(address _portefeuille) public view returns (uint256) {
        Contrepartie memory c = contreparties[_portefeuille];
        require(c.expositionCourante > 0, "Exposition courante nulle");
        return (c.collateral * 100) / c.expositionCourante;
    }

    /**
     * @notice Calcul du score de risque selon les notes de cours :
     * Score de Risque = ((Exposition Courante / Limite d’Exposition) * 100) / Score de Crédit
     */
    function calculerScoreRisque(address _portefeuille) public view returns (uint256) {
        Contrepartie memory c = contreparties[_portefeuille];
        require(c.limiteExposition > 0, "Limite d'exposition invalide");
        require(c.scoreCredit > 0, "Score de credit invalide");

        uint256 ratio = (c.expositionCourante * 100) / c.limiteExposition;
        return ratio / c.scoreCredit;
    }

    /**
     * @notice Calcul des pertes attendues (Expected Loss):
     * PA = ExpositionCourante * PD * LGD
     * PD et LGD sont en pourcentage (par exemple 2% = 2)
     * On suppose ici PD et LGD fournis à l'appel.
     */
    function calculerPertesAttendues(address _portefeuille, uint256 PD, uint256 LGD) public view returns (uint256) {
        require(PD <= 100 && LGD <= 100, "PD et LGD doivent etre des pourcentages (0-100)");
        Contrepartie memory c = contreparties[_portefeuille];
        // Convertir PD et LGD en pourcentages : PD% = PD/100, LGD% = LGD/100
        // PA = ExpositionCourante * (PD/100) * (LGD/100) = ExpositionCourante * PD * LGD / 10000
        return (c.expositionCourante * PD * LGD) / 10000;
    }

    /**
     * @notice Vérifier si la contrepartie dépasse les limites et appliquer pénalités si nécessaire.
     */
    function verifierDepassements(address _portefeuille) internal {
        Contrepartie storage c = contreparties[_portefeuille];

        if (c.expositionCourante > c.limiteExposition) {
            nombreDepassements[_portefeuille]++;
            emit LimiteDepassee(_portefeuille, c.expositionCourante, c.limiteExposition);

            // Si dépassement répété, appliquer pénalité et réduire le score de crédit
            if (nombreDepassements[_portefeuille] >= 3) {
                appliquerPenalite(_portefeuille);
                c.scoreCredit = c.scoreCredit > 10 ? c.scoreCredit - 10 : 1; // On ne descend pas à 0 pour eviter division par 0
            }
        }

        if (c.expositionCourante > 0) {
            uint256 ratioCouverture = calculerRatioCouverture(_portefeuille);
            if (ratioCouverture < 100) {
                emit RatioCouvertureInsuffisant(_portefeuille, ratioCouverture);
            }
        }
    }

    /**
     * @notice Appliquer une pénalité de 10% de l’exposition courante.
     */
    function appliquerPenalite(address _portefeuille) internal {
        Contrepartie storage c = contreparties[_portefeuille];
        uint256 penalite = (c.expositionCourante * 10) / 100; // Pénalité de 10%
        if (c.collateral >= penalite) {
            c.collateral -= penalite;
        } else {
            c.collateral = 0;
        }
        c.penalites += penalite;

        emit PenaliteAppliquee(_portefeuille, penalite);
    }

    /**
     * @notice Ajouter du collatéral pour une contrepartie.
     */
    function ajouterCollateral(address _portefeuille, uint256 montant) public {
        require(montant > 0, "Montant doit etre superieur a 0");
        Contrepartie storage c = contreparties[_portefeuille];
        require(c.estActif, "Contrepartie inactive");
        c.collateral += montant;

        emit CollateralMisAJour(_portefeuille, c.collateral);
    }

    /**
     * @notice Retirer du collatéral si le ratio de couverture >= 150%.
     */
    function retirerCollateral(address _portefeuille, uint256 montant) public {
        require(montant > 0, "Montant doit etre superieur a 0");
        Contrepartie storage c = contreparties[_portefeuille];
        require(c.estActif, "Contrepartie inactive");
        require(calculerRatioCouverture(_portefeuille) >= 150, "Ratio insuffisant pour retirer des collateraux");

        if (c.collateral >= montant) {
            c.collateral -= montant;
        } else {
            c.collateral = 0;
        }

        emit CollateralMisAJour(_portefeuille, c.collateral);
    }

    /**
     * @notice Désactiver une contrepartie.
     */
    function desactiverContrepartie(address _portefeuille) public {
        Contrepartie storage c = contreparties[_portefeuille];
        require(c.estActif, "Contrepartie deja inactive");
        c.estActif = false;

        emit ContrepartieDesactivee(_portefeuille);
    }

    /**
     * @notice Voir toutes les contreparties avec leurs limites et expositions.
     */
    function voirToutesLesContreparties() public view returns (address[] memory, uint256[] memory, uint256[] memory) {
        uint256[] memory limites = new uint256[](listeContreparties.length);
        uint256[] memory expositions = new uint256[](listeContreparties.length);

        for (uint256 i = 0; i < listeContreparties.length; i++) {
            Contrepartie memory c = contreparties[listeContreparties[i]];
            limites[i] = c.limiteExposition;
            expositions[i] = c.expositionCourante;
        }

        return (listeContreparties, limites, expositions);
    }
}